//! Shared termination authority for native V8 invocations.

use std::sync::Mutex;
use std::sync::atomic::{AtomicU8, Ordering};

/// Marks an isolate that can still accept one termination reason.
pub(crate) const EXECUTION_RUNNING: u8 = 0;
/// Records that the watchdog ended the run.
pub(crate) const TERMINATION_TIMEOUT: u8 = 1;
/// Records that the V8 heap limit ended the run.
pub(crate) const TERMINATION_HEAP: u8 = 2;
/// Records that the caller ended the run.
pub(crate) const TERMINATION_CANCELLED: u8 = 3;
/// Prevents termination while the host reads the final state.
pub(crate) const EXECUTION_FINISHING: u8 = 4;
/// Marks a run whose final state is no longer mutable.
pub(crate) const EXECUTION_DONE: u8 = 5;

/// One cancellation authority for the V8 isolate that is currently running.
/// Watchdog, heap pressure, and caller cancellation all race through the same
/// execution phase, so V8 is terminated at most once and never after the host
/// starts finishing.
pub(crate) struct RunControl {
    pub(crate) execution_phase: AtomicU8,
    pub(crate) isolate: Mutex<Option<deno_core::v8::IsolateHandle>>,
}

impl RunControl {
    pub(crate) fn new() -> Self {
        Self {
            execution_phase: AtomicU8::new(EXECUTION_RUNNING),
            isolate: Mutex::new(None),
        }
    }

    pub(crate) fn install_isolate(&self, handle: deno_core::v8::IsolateHandle) {
        let mut isolate = self
            .isolate
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        *isolate = Some(handle.clone());

        if matches!(
            self.execution_phase.load(Ordering::SeqCst),
            TERMINATION_CANCELLED | TERMINATION_TIMEOUT | TERMINATION_HEAP
        ) {
            handle.terminate_execution();
        }
    }

    pub(crate) fn clear_isolate(&self) {
        self.isolate
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .take();
    }

    pub(crate) fn terminate(&self, reason: u8) {
        if self
            .execution_phase
            .compare_exchange(
                EXECUTION_RUNNING,
                reason,
                Ordering::SeqCst,
                Ordering::SeqCst,
            )
            .is_ok()
            && let Some(handle) = self
                .isolate
                .lock()
                .unwrap_or_else(|error| error.into_inner())
                .as_ref()
        {
            handle.terminate_execution();
        }
    }
}
