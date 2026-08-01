#![allow(
    dead_code,
    reason = "feature-gated host builds use different cache operations"
)]

use std::collections::HashMap;
use std::hash::Hash;
use std::sync::Mutex;

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

    pub(crate) fn get_if<R>(
        &self,
        key: &K,
        matches: impl FnOnce(&V) -> bool,
        clone_value: impl FnOnce(&V) -> R,
    ) -> Option<R> {
        let guard = self.entries.try_lock().ok()?;
        let cached = guard.get(key)?;

        matches(cached).then(|| clone_value(cached))
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
