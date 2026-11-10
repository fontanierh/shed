//! WebSocket endpoint: one connection per client app, fanning out session events it has attached to.

use std::collections::HashMap;
use std::sync::Arc;

use anyhow::Result;
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{Query, State};
use axum::http::{header::AUTHORIZATION, HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use tokio::sync::{broadcast::error::RecvError, mpsc};

use crate::channel::Offer;
use crate::protocol::{ClientMessage, ClientOp, ServerMessage};
use crate::session::{attach_snapshot, App};

pub async fn ws_handler(
    ws: WebSocketUpgrade,
    Query(query): Query<HashMap<String, String>>,
    headers: HeaderMap,
    State(app): State<Arc<App>>,
) -> Response {
    if !authorized(&app, &query, &headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    ws.on_upgrade(move |socket| client_loop(app, socket))
}

/// The bridge token, presented as `?token=` or as a bearer token.
pub fn authorized(app: &App, query: &HashMap<String, String>, headers: &HeaderMap) -> bool {
    let presented = query.get("token").cloned().or_else(|| {
        headers
            .get(AUTHORIZATION)
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.strip_prefix("Bearer "))
            .map(str::to_string)
    });
    presented.is_some_and(|t| constant_time_eq(t.as_bytes(), app.token.as_bytes()))
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

fn encode(msg: &ServerMessage) -> Arc<str> {
    serde_json::to_string(msg)
        .expect("server messages serialize")
        .into()
}

fn reply(id: Option<String>, result: Result<Value>) -> Arc<str> {
    encode(&match result {
        Ok(data) => ServerMessage::Reply {
            id,
            ok: true,
            data: Some(data),
            error: None,
        },
        Err(e) => ServerMessage::Reply {
            id,
            ok: false,
            data: None,
            error: Some(e.to_string()),
        },
    })
}

async fn client_loop(app: Arc<App>, socket: WebSocket) {
    let (mut sink, mut stream) = socket.split();
    let (out, mut out_rx) = mpsc::unbounded_channel::<Arc<str>>();
    let writer = tokio::spawn(async move {
        while let Some(text) = out_rx.recv().await {
            if sink
                .send(Message::Text(text.as_ref().into()))
                .await
                .is_err()
            {
                break;
            }
        }
    });

    let mut hub = app.hub.subscribe();
    // Session id -> sequence number of the snapshot this client received.
    let mut attached: HashMap<String, u64> = HashMap::new();
    out.offer(encode(&ServerMessage::Sessions {
        sessions: app.summaries().await,
    }));

    loop {
        tokio::select! {
            incoming = stream.next() => match incoming {
                Some(Ok(Message::Text(text))) => handle_text(&app, &out, &mut attached, text.as_str()).await,
                Some(Ok(Message::Close(_))) | Some(Err(_)) | None => break,
                Some(Ok(_)) => {}
            },
            envelope = hub.recv() => match envelope {
                Ok(env) => match &env.session_id {
                    None => out.offer(env.json.clone()),
                    Some(id) => {
                        if attached.get(id).is_some_and(|&snap| env.seq > snap) {
                            out.offer(env.json.clone());
                        }
                    }
                },
                // This client fell behind: resend full snapshots instead of the events it missed.
                Err(RecvError::Lagged(_)) => {
                    let ids: Vec<String> = attached.keys().cloned().collect();
                    for id in ids {
                        if let Ok(session) = app.find(&id).await {
                            send_snapshot(&out, &mut attached, &session).await;
                        }
                    }
                    out.offer(encode(&ServerMessage::Sessions { sessions: app.summaries().await }));
                }
                Err(RecvError::Closed) => break,
            },
        }
    }
    writer.abort();
}

async fn send_snapshot(
    out: &mpsc::UnboundedSender<Arc<str>>,
    attached: &mut HashMap<String, u64>,
    session: &crate::session::Session,
) {
    let (seq, summary, snapshot) = attach_snapshot(session).await;
    out.offer(encode(&ServerMessage::Session {
        session: Box::new(summary),
    }));
    out.offer(encode(&snapshot));
    attached.insert(session.id.clone(), seq);
}

async fn handle_text(
    app: &Arc<App>,
    out: &mpsc::UnboundedSender<Arc<str>>,
    attached: &mut HashMap<String, u64>,
    text: &str,
) {
    let message: ClientMessage = match serde_json::from_str(text) {
        Ok(m) => m,
        Err(e) => {
            let id = serde_json::from_str::<Value>(text)
                .ok()
                .and_then(|v| v["id"].as_str().map(str::to_string));
            out.offer(reply(id, Err(anyhow::anyhow!("invalid message: {e}"))));
            return;
        }
    };
    let id = message.id;
    // Attach and detach run inline so the snapshot sequence stays ordered with forwarded events.
    match message.op {
        ClientOp::Attach { session_id } => {
            let result = match app.find(&session_id).await {
                Ok(session) => match app.ensure_attached(&session).await {
                    Ok(()) => {
                        send_snapshot(out, attached, &session).await;
                        Ok(Value::Null)
                    }
                    Err(e) => Err(e),
                },
                Err(e) => Err(e),
            };
            out.offer(reply(id, result));
        }
        ClientOp::Detach { session_id } => {
            attached.remove(&session_id);
            out.offer(reply(id, Ok(Value::Null)));
        }
        op => {
            // Everything else may wait on the agent (compaction can take minutes), so run it apart
            // from the event loop.
            let (app, out) = (app.clone(), out.clone());
            tokio::spawn(async move {
                let result = run_op(&app, op).await;
                out.offer(reply(id, result));
            });
        }
    }
}

async fn run_op(app: &Arc<App>, op: ClientOp) -> Result<Value> {
    Ok(match op {
        ClientOp::Attach { .. } | ClientOp::Detach { .. } => unreachable!("handled inline"),
        ClientOp::ListSessions => serde_json::to_value(app.summaries().await)?,
        ClientOp::Ping => Value::Null,
        ClientOp::CreateSession {
            agent,
            cwd,
            model,
            thinking,
        } => serde_json::to_value(app.create_session(agent, cwd, model, thinking).await?)?,
        ClientOp::Send { session_id, text } => {
            let session = app.find(&session_id).await?;
            app.send_text(&session, text).await?
        }
        ClientOp::FollowUp { session_id, text } => {
            let session = app.find(&session_id).await?;
            app.command(&session, "follow_up", json!({ "message": text }))
                .await?
        }
        ClientOp::Abort { session_id } => {
            let session = app.find(&session_id).await?;
            app.command(&session, "abort", json!({})).await?
        }
        ClientOp::StopTool { session_id } => {
            let session = app.find(&session_id).await?;
            app.stop_tool(&session).await?
        }
        ClientOp::Compact {
            session_id,
            instructions,
        } => {
            let session = app.find(&session_id).await?;
            let result = app.compact(&session, instructions).await?;
            app.refresh(&session).await?;
            result
        }
        ClientOp::NewSession { session_id } => {
            let session = app.find(&session_id).await?;
            app.new_session(&session).await?
        }
        ClientOp::ListModels { session_id } => {
            let session = app.find(&session_id).await?;
            let data = app
                .command(&session, "get_available_models", json!({}))
                .await?;
            let mut models = crate::agent_wire::models(&data);
            // With Open Codex, a session switches among its models only, like the new-session list.
            if crate::opencodex::gateway().is_some() {
                models.retain(|m| m.provider == crate::opencodex::PROVIDER);
            }
            serde_json::to_value(models)?
        }
        ClientOp::SetModel {
            session_id,
            provider,
            model_id,
        } => {
            let session = app.find(&session_id).await?;
            app.command(
                &session,
                "set_model",
                json!({ "provider": provider, "modelId": model_id }),
            )
            .await?;
            app.refresh(&session).await?;
            Value::Null
        }
        ClientOp::SetThinking { session_id, level } => {
            let session = app.find(&session_id).await?;
            app.command(&session, "set_thinking_level", json!({ "level": level }))
                .await?;
            app.refresh(&session).await?;
            Value::Null
        }
        ClientOp::SetAutoCompaction {
            session_id,
            enabled,
        } => {
            let session = app.find(&session_id).await?;
            app.command(
                &session,
                "set_auto_compaction",
                json!({ "enabled": enabled }),
            )
            .await?;
            app.refresh(&session).await?;
            Value::Null
        }
        ClientOp::ResumeSession { session_id } => {
            let session = app.find(&session_id).await?;
            serde_json::to_value(app.resume_session(&session).await?)?
        }
        ClientOp::RenameSession { session_id, name } => {
            let session = app.find(&session_id).await?;
            app.rename_session(&session, &name).await?;
            Value::Null
        }
        ClientOp::SetContextLimit { session_id, limit } => {
            let session = app.find(&session_id).await?;
            app.set_context_limit(&session, limit).await?;
            Value::Null
        }
        ClientOp::ClearGoal { session_id } => {
            let session = app.find(&session_id).await?;
            app.clear_goal(&session).await?
        }
        ClientOp::RestartKernel { session_id } => {
            let session = app.find(&session_id).await?;
            app.restart_kernel(&session).await?
        }
        ClientOp::CloseSession { session_id } => {
            let session = app.find(&session_id).await?;
            app.close_session(&session).await?;
            Value::Null
        }
        ClientOp::DeleteSession { session_id } => {
            let session = app.find(&session_id).await?;
            app.delete_session(&session).await?;
            Value::Null
        }
        ClientOp::ListJobs { session_id } => {
            let session = app.find(&session_id).await?;
            serde_json::to_value(app.list_jobs(&session).await?)?
        }
        ClientOp::JobOutput {
            session_id,
            job_id,
            lines,
        } => {
            let session = app.find(&session_id).await?;
            json!({ "tail": app.job_output(&session, &job_id, lines).await? })
        }
        ClientOp::KillJob { session_id, job_id } => {
            let session = app.find(&session_id).await?;
            json!({ "killed": app.kill_job(&session, &job_id).await? })
        }
        ClientOp::AnswerQuestion {
            session_id,
            question_id,
            answers,
        } => {
            let session = app.find(&session_id).await?;
            app.command(
                &session,
                "dsh_answer",
                json!({ "questionId": question_id, "answers": answers }),
            )
            .await?;
            Value::Null
        }
        ClientOp::LoadEarlier { session_id, before } => {
            let session = app.find(&session_id).await?;
            let (items, earlier) = session.state.lock().await.earlier_page(&before);
            json!({ "items": items, "earlier": earlier })
        }
        ClientOp::ListAgentModels { agent } => {
            json!({ "models": crate::rpc::list_models(agent).await? })
        }
        ClientOp::ListDir { path, hidden } => crate::files::list_dir(path.as_deref(), hidden)?,
        ClientOp::GitBranch { path } => crate::git::branch(&path).await,
        ClientOp::GithubOverview => crate::github::overview().await?,
    })
}
