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

use crate::ask::Ask;
use crate::channel::Offer;
use crate::protocol::{ClientMessage, ClientOp, Failure, ServerMessage};
use crate::session::{attach_snapshot, App, Session};

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
            code: None,
        },
        Err(e) => ServerMessage::Reply {
            id,
            ok: false,
            data: None,
            error: Some(e.to_string()),
            code: e.downcast_ref::<Failure>().map(|failure| failure.code),
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
    // One message at a time, as `serve` takes them: a client that sends faster than they are taken waits.
    let (texts, incoming) = mpsc::channel::<String>(1);
    let reader = tokio::spawn(async move {
        loop {
            match stream.next().await {
                Some(Ok(Message::Text(text))) => {
                    if texts.send(text.as_str().to_string()).await.is_err() {
                        break;
                    }
                }
                Some(Ok(Message::Close(_))) | Some(Err(_)) | None => break,
                Some(Ok(_)) => {}
            }
        }
    });
    serve(app, incoming, out).await;
    reader.abort();
    writer.abort();
}

/// An attach whose wait on the agent is over: who asked, for which session, and how it went.
type Attached = (Option<String>, String, Result<Arc<Session>>);

/// One client: what it sends arrives on `incoming`, and what it is sent leaves on `out`. It ends when `incoming`
/// does.
pub(crate) async fn serve(
    app: Arc<App>,
    mut incoming: mpsc::Receiver<String>,
    out: mpsc::UnboundedSender<Arc<str>>,
) {
    let mut hub = app.hub.subscribe();
    // Session id -> sequence number of the snapshot this client received.
    let mut attached: HashMap<String, u64> = HashMap::new();
    // Attaches still waiting on their agent, by session: how many, so a detach meanwhile calls them all off.
    let mut attaching: HashMap<String, usize> = HashMap::new();
    let (attach_done, mut attaches) = mpsc::unbounded_channel::<Attached>();
    out.offer(encode(&ServerMessage::Sessions {
        sessions: app.summaries().await,
        bridge: crate::protocol::BRIDGE,
    }));

    loop {
        tokio::select! {
            text = incoming.recv() => match text {
                Some(text) => handle_text(&app, &out, &mut attached, &mut attaching, &attach_done, &text),
                None => break,
            },
            Some((id, session_id, result)) = attaches.recv() => {
                // The snapshot is taken here, on the loop that forwards events, so its sequence number and the
                // events after it stay in order.
                let wanted = match attaching.get_mut(&session_id) {
                    Some(count) => {
                        *count -= 1;
                        if *count == 0 {
                            attaching.remove(&session_id);
                        }
                        true
                    }
                    // Detached while it waited: answered, and not attached.
                    None => false,
                };
                let result = match result {
                    Ok(session) => {
                        if wanted {
                            send_snapshot(&out, &mut attached, &session).await;
                        }
                        Ok(Value::Null)
                    }
                    Err(e) => Err(e),
                };
                out.offer(reply(id, result));
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
                    out.offer(encode(&ServerMessage::Sessions {
                        sessions: app.summaries().await,
                        bridge: crate::protocol::BRIDGE,
                    }));
                }
                Err(RecvError::Closed) => break,
            },
        }
    }
}

async fn send_snapshot(
    out: &mpsc::UnboundedSender<Arc<str>>,
    attached: &mut HashMap<String, u64>,
    session: &Session,
) {
    let (seq, summary, snapshot) = attach_snapshot(session).await;
    out.offer(encode(&ServerMessage::Session {
        session: Box::new(summary),
    }));
    out.offer(encode(&snapshot));
    attached.insert(session.id.clone(), seq);
}

fn handle_text(
    app: &Arc<App>,
    out: &mpsc::UnboundedSender<Arc<str>>,
    attached: &mut HashMap<String, u64>,
    attaching: &mut HashMap<String, usize>,
    attach_done: &mpsc::UnboundedSender<Attached>,
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
    match message.op {
        // The wait on the agent (Prime's daemon may take its time) runs apart, so this client's other requests and
        // its events go on meanwhile. `serve` takes the snapshot when the wait is over.
        ClientOp::Attach { session_id } => {
            *attaching.entry(session_id.clone()).or_default() += 1;
            let (app, done) = (app.clone(), attach_done.clone());
            tokio::spawn(async move {
                let result = match app.find(&session_id).await {
                    Ok(session) => app.ensure_attached(&session).await.map(|()| session),
                    Err(e) => Err(e),
                };
                done.offer((id, session_id, result));
            });
        }
        ClientOp::Detach { session_id } => {
            attached.remove(&session_id);
            attaching.remove(&session_id);
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
        ClientOp::Send {
            session_id,
            text,
            send_id,
        } => {
            let session = app.find(&session_id).await?;
            app.send_text(&session, text, send_id).await?
        }
        ClientOp::FollowUp { session_id, text } => {
            let session = app.find(&session_id).await?;
            app.command(&session, Ask::FollowUp(text)).await?
        }
        ClientOp::Abort { session_id } => {
            let session = app.find(&session_id).await?;
            app.command(&session, Ask::Abort).await?
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
            let data = app.command(&session, Ask::Models).await?;
            let mut models = crate::agent_wire::models(&data);
            // With Open Codex, a session switches among its models only, like the new-session list.
            if crate::opencodex::gateway(&app.store).is_some() {
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
            app.command(&session, Ask::SetModel { provider, model_id })
                .await?;
            app.refresh(&session).await?;
            Value::Null
        }
        ClientOp::SetThinking { session_id, level } => {
            let session = app.find(&session_id).await?;
            app.command(&session, Ask::SetThinkingLevel(level)).await?;
            app.refresh(&session).await?;
            Value::Null
        }
        ClientOp::SetAutoCompaction {
            session_id,
            enabled,
        } => {
            let session = app.find(&session_id).await?;
            app.command(&session, Ask::SetAutoCompaction(enabled))
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
                Ask::Answer {
                    question_id,
                    answers,
                },
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
            json!({ "models": app.list_models(agent).await? })
        }
        ClientOp::ListDir { path, hidden } => crate::files::list_dir(path.as_deref(), hidden)?,
        ClientOp::GitBranch { path } => crate::git::branch(&path).await,
        ClientOp::GithubOverview => crate::github::overview().await?,
    })
}
