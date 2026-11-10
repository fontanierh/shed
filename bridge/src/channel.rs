//! Sends that may find nobody listening.

#![expect(
    clippy::let_underscore_must_use,
    reason = "the one place a send that fails is dropped"
)]

use tokio::sync::{broadcast, mpsc, oneshot, watch};

/// A send whose other end may be gone: a client that hung up, a caller that stopped waiting, a bridge that is
/// shutting down. Nobody is left to tell, so a send that fails is dropped.
///
/// Only channels get this. The linter rejects any other ignored result (`clippy::let_underscore_must_use`).
pub trait Offer<T> {
    fn offer(self, value: T);
}

impl<T> Offer<T> for &mpsc::UnboundedSender<T> {
    fn offer(self, value: T) {
        let _ = self.send(value);
    }
}

impl<T> Offer<T> for &broadcast::Sender<T> {
    fn offer(self, value: T) {
        let _ = self.send(value);
    }
}

impl<T> Offer<T> for &watch::Sender<T> {
    fn offer(self, value: T) {
        let _ = self.send(value);
    }
}

impl<T> Offer<T> for oneshot::Sender<T> {
    fn offer(self, value: T) {
        let _ = self.send(value);
    }
}
