#![allow(
    dead_code,
    reason = "feature-gated host builds use different cache operations"
)]

use std::borrow::Borrow;
use std::collections::HashMap;
use std::hash::Hash;
use std::sync::Mutex;

/// A cache hit is not part of correctness.
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
        if self.max_entries == 0 {
            return;
        }

        let mut guard = self.entries.lock().expect("bounded cache lock");

        if let Some(existing) = guard.get_mut(&key) {
            *existing = value;
            return;
        }

        if guard.len() >= self.max_entries
            && let Some(old_key) = guard.keys().next().cloned()
        {
            guard.remove(&old_key);
        }

        guard.insert(key, value);
    }

    #[cfg(test)]
    pub(crate) fn len(&self) -> usize {
        self.entries.lock().expect("bounded cache lock").len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn replacing_and_inserting_entries_stays_within_capacity() {
        let cache = BoundedCache::new(2);
        cache.insert("first", 1);
        cache.insert("second", 2);

        cache.insert("first", 3);

        assert_eq!(cache.get_cloned("first"), Some(3));
        assert_eq!(cache.get_cloned("second"), Some(2));
        assert_eq!(cache.len(), 2);

        cache.insert("third", 4);

        assert_eq!(cache.get_cloned("third"), Some(4));
        assert_eq!(cache.len(), 2);
    }
}
