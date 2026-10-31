//! Spots a model stuck in a generation loop while it streams: a tool call whose arguments turned into nothing but
//! whitespace, or text repeating the same few characters over and over. Left alone, such a reply runs until the model's
//! output limit (a quarter of an hour or more) with nothing to show for it, and the session looks stuck.

/// Whitespace in a row that no real reply contains.
const MAX_BLANK_RUN: usize = 4_000;
/// How much of the end of a reply the repetition check looks at, how often it looks, and the longest repeating unit
/// it recognizes: 16 KB of one short unit over and over is a loop, not content.
const WINDOW: usize = 16_000;
const CHECK_EVERY: usize = 4_000;
const MAX_PERIOD: usize = 256;

#[derive(Default)]
pub struct Runaway {
    /// The end of the block streaming now, up to `WINDOW` bytes.
    tail: Vec<u8>,
    /// Whitespace bytes at the very end of it.
    blank_run: usize,
    since_check: usize,
}

impl Runaway {
    /// A new block (text, reasoning or a tool call) started streaming.
    pub fn reset(&mut self) {
        *self = Self::default();
    }

    /// Takes the next delta of the streaming block; says why when the block has turned into a loop.
    pub fn feed(&mut self, delta: &str) -> Option<&'static str> {
        for &byte in delta.as_bytes() {
            if byte.is_ascii_whitespace() {
                self.blank_run += 1;
            } else {
                self.blank_run = 0;
            }
        }
        if self.blank_run >= MAX_BLANK_RUN {
            return Some("it had turned into thousands of blank characters");
        }
        self.tail.extend_from_slice(delta.as_bytes());
        if self.tail.len() > WINDOW * 2 {
            self.tail.drain(..self.tail.len() - WINDOW);
        }
        self.since_check += delta.len();
        if self.since_check >= CHECK_EVERY && self.tail.len() >= WINDOW {
            self.since_check = 0;
            let window = &self.tail[self.tail.len() - WINDOW..];
            if (1..=MAX_PERIOD).any(|period| window[period..].iter().zip(window).all(|(a, b)| a == b)) {
                return Some("it was repeating the same few characters over and over");
            }
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn feed_all(chunks: impl IntoIterator<Item = String>) -> Option<&'static str> {
        let mut guard = Runaway::default();
        chunks.into_iter().find_map(|chunk| guard.feed(&chunk))
    }

    #[test]
    fn trips_on_endless_whitespace() {
        // What a looping model streamed into a tool call's arguments.
        let chunks = std::iter::repeat(" \t\t\t\t\t\t\t\t\n      ".to_string()).take(1_000);
        assert!(feed_all(chunks).is_some());
    }

    #[test]
    fn trips_on_a_repeated_phrase() {
        let chunks = std::iter::repeat("I'll check the build again. ".to_string()).take(2_000);
        assert!(feed_all(chunks).is_some());
    }

    #[test]
    fn leaves_real_code_alone() {
        // Long, indented, repetitive-looking code is still not one unit repeated exactly.
        let chunks = (0..3_000).map(|i| format!("    values[{i}] = compute({i}, \"key-{}\")\n", i % 7));
        assert!(feed_all(chunks).is_none());
    }

    #[test]
    fn a_new_block_starts_over() {
        let mut guard = Runaway::default();
        assert!(guard.feed(&" ".repeat(MAX_BLANK_RUN - 10)).is_none());
        guard.reset();
        assert!(guard.feed(&" ".repeat(20)).is_none());
    }
}
