//! Requests sent to an agent, each waiting for its answer, and for no longer than a limit: an agent that stops
//! answering must not hold up whoever asked.

use std::borrow::Borrow;
use std::collections::HashMap;
use std::hash::Hash;
use std::sync::Mutex;
use std::time::Duration;

use serde_json::Value;
use tokio::sync::oneshot;

use crate::channel::Offer;

/// What the agent said: its data, or its refusal.
pub type Answer = Result<Value, String>;

/// Enough for anything an agent answers from what it already holds.
pub const QUICK: Duration = Duration::from_secs(120);
/// For the requests an agent answers only once the model is done, such as a compaction.
pub const SLOW: Duration = Duration::from_secs(30 * 60);

/// Why a request got no answer.
#[derive(Debug, PartialEq)]
pub enum Unanswered {
    /// The agent went away first.
    Gone,
    /// It is still there and said nothing for this long.
    Late(Duration),
}

pub struct Requests<K> {
    waiting: Mutex<HashMap<K, oneshot::Sender<Answer>>>,
}

impl<K> Default for Requests<K> {
    fn default() -> Self {
        Requests {
            waiting: Mutex::new(HashMap::new()),
        }
    }
}

impl<K: Eq + Hash + Clone> Requests<K> {
    /// Call before sending the request, so an answer can't arrive first.
    pub fn ask(&self, id: K) -> Asked<'_, K> {
        let (tx, rx) = oneshot::channel();
        self.waiting.lock().unwrap().insert(id.clone(), tx);
        Asked {
            requests: self,
            id,
            rx,
        }
    }

    /// An answer nobody waits for any more is dropped.
    pub fn answer<Q>(&self, id: &Q, answer: Answer)
    where
        K: Borrow<Q>,
        Q: Eq + Hash + ?Sized,
    {
        let waiter = self.waiting.lock().unwrap().remove(id);
        if let Some(waiter) = waiter {
            waiter.offer(answer);
        }
    }

    /// The agent is gone: every request still waiting is refused with `reason`.
    pub fn refuse_all(&self, reason: &str) {
        let waiters: Vec<_> = self.waiting.lock().unwrap().drain().collect();
        for (_, waiter) in waiters {
            waiter.offer(Err(reason.to_string()));
        }
    }

    /// The agent is gone, and the requests still waiting end as `Unanswered::Gone`, not as a refusal.
    pub fn drop_all(&self) {
        self.waiting.lock().unwrap().clear();
    }
}

/// A request that was registered. Dropping it, answered or not, forgets it.
pub struct Asked<'a, K: Eq + Hash> {
    requests: &'a Requests<K>,
    id: K,
    rx: oneshot::Receiver<Answer>,
}

impl<K: Eq + Hash> Asked<'_, K> {
    pub async fn answer(mut self, limit: Duration) -> Result<Answer, Unanswered> {
        match tokio::time::timeout(limit, &mut self.rx).await {
            Ok(Ok(answer)) => Ok(answer),
            Ok(Err(_)) => Err(Unanswered::Gone),
            Err(_) => Err(Unanswered::Late(limit)),
        }
    }
}

impl<K: Eq + Hash> Drop for Asked<'_, K> {
    fn drop(&mut self) {
        self.requests.waiting.lock().unwrap().remove(&self.id);
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    fn waiting(requests: &Requests<u64>) -> usize {
        requests.waiting.lock().unwrap().len()
    }

    #[tokio::test]
    async fn an_answer_reaches_whoever_asked() {
        let requests = Requests::default();
        let asked = requests.ask(1);
        requests.answer(&1, Ok(json!("hello")));
        assert_eq!(asked.answer(QUICK).await, Ok(Ok(json!("hello"))));
        assert_eq!(waiting(&requests), 0);
    }

    #[tokio::test(start_paused = true)]
    async fn an_agent_that_says_nothing_is_given_up_on_and_its_late_answer_dropped() {
        let requests = Requests::default();
        let asked = requests.ask(1);
        assert_eq!(asked.answer(QUICK).await, Err(Unanswered::Late(QUICK)));
        assert_eq!(waiting(&requests), 0);
        requests.answer(&1, Ok(Value::Null));
    }

    #[tokio::test]
    async fn an_agent_that_exits_refuses_what_was_waiting() {
        let requests = Requests::default();
        let asked = requests.ask(1);
        requests.refuse_all("agent exited: code 1");
        assert_eq!(
            asked.answer(QUICK).await,
            Ok(Err("agent exited: code 1".into()))
        );
    }

    #[tokio::test]
    async fn a_dropped_connection_is_not_a_refusal() {
        let requests = Requests::default();
        let asked = requests.ask(1);
        requests.drop_all();
        assert_eq!(asked.answer(QUICK).await, Err(Unanswered::Gone));
    }

    #[tokio::test]
    async fn a_request_that_could_not_be_sent_is_forgotten() {
        let requests = Requests::default();
        drop(requests.ask(1));
        assert_eq!(waiting(&requests), 0);
    }
}
