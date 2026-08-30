#![allow(
    dead_code,
    reason = "feature-gated host builds use different cache operations"
)]

use std::borrow::Borrow;
use std::collections::HashMap;
use std::hash::Hash;
use std::sync::Mutex;

/// Stores derived values without making a cache hit part of correctness.
/// Contended reads can miss, and eviction is arbitrary. This avoids wait time
/// on cache reads and avoids recency bookkeeping.
pub(crate) struct BoundedCache<K, V> {
    max_entries: usize,
    entries: Mutex<HashMap<K, V>>,
}

impl<K, V> BoundedCache<K, V>
where
    K: Clone + Eq + Hash,
{
    pub(crate) fn new(max_entries: usize) -> Self {
        Self {
            max_entries,
            entries: Mutex::new(HashMap::new()),
        }
    }

    pub(crate) fn get_cloned<Q>(&self, key: &Q) -> Option<V>
    where
        K: Borrow<Q>,
        Q: Eq + Hash + ?Sized,
        V: Clone,
    {
        let guard = self.entries.try_lock().ok()?;
        guard.get(key).cloned()
    }

    pub(crate) fn insert(&self, key: K, value: V) {
        let mut guard = match self.entries.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        };

        if !guard.contains_key(&key)
            && guard.len() >= self.max_entries
            && let Some(old_key) = guard.keys().next().cloned()
        {
            guard.remove(&old_key);
        }

        guard.insert(key, value);
    }

    #[cfg(test)]
    pub(crate) fn clear(&self) {
        self.entries.lock().expect("bounded cache lock").clear();
    }

    #[cfg(test)]
    pub(crate) fn len(&self) -> usize {
        self.entries.lock().expect("bounded cache lock").len()
    }
}
