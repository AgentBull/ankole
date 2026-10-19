//! ArrayBuffer allocations share the invocation's heap budget. The allocator
//! refuses a large external allocation before V8 can reserve host memory.

use crate::isolate_control::{RunControl, TERMINATION_HEAP};
use deno_core::v8;
use std::alloc::{Layout, alloc, alloc_zeroed, dealloc};
use std::ffi::c_void;
use std::ptr;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

pub(super) struct Budget {
    limit: usize,
    external: AtomicUsize,
    heap: AtomicUsize,
    control: Arc<RunControl>,
}
impl Budget {
    pub(super) fn new(limit: usize, control: Arc<RunControl>) -> Arc<Self> {
        Arc::new(Self {
            limit,
            external: AtomicUsize::new(0),
            heap: AtomicUsize::new(0),
            control,
        })
    }
    pub(super) fn allocator(self: &Arc<Self>) -> v8::UniqueRef<v8::Allocator> {
        static VTABLE: v8::RustAllocatorVtable<Budget> = v8::RustAllocatorVtable {
            allocate,
            allocate_uninitialized,
            free,
            drop: drop_budget,
        };
        // SAFETY: The raw Arc owns one reference for the complete allocator
        // lifetime. Its type matches VTABLE, whose destructor releases it.
        unsafe { v8::new_rust_allocator(Arc::into_raw(Arc::clone(self)), &VTABLE) }
    }
    pub(super) fn check(self: &Arc<Self>) {
        if let Some(handle) = self
            .control
            .isolate
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .as_ref()
        {
            // The allocator retains this Budget until isolate destruction.
            // V8 only invokes this callback while that isolate still exists.
            handle.request_interrupt(check_total, Arc::as_ptr(self) as *mut c_void);
        }
    }
    pub(super) fn check_now(&self, isolate: &mut v8::Isolate) {
        let heap = isolate.get_heap_statistics().used_heap_size();
        self.heap.store(heap, Ordering::SeqCst);
        if heap.saturating_add(self.external.load(Ordering::SeqCst)) > self.limit {
            self.control.terminate(TERMINATION_HEAP);
        }
    }

    pub(super) fn retain(self: &Arc<Self>, size: usize) -> Option<Reservation> {
        self.reserve(size).then(|| Reservation {
            budget: Arc::clone(self),
            size,
        })
    }
    pub(super) fn charge_retained(&self, size: usize) -> bool {
        self.reserve(size)
    }

    fn reserve(&self, size: usize) -> bool {
        let heap = self.heap.load(Ordering::SeqCst);
        if self
            .external
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |current| {
                current
                    .checked_add(size)
                    .filter(|next| next.saturating_add(heap) <= self.limit)
            })
            .is_err()
        {
            self.control.terminate(TERMINATION_HEAP);
            false
        } else {
            true
        }
    }
}
pub(super) struct Reservation {
    budget: Arc<Budget>,
    size: usize,
}
impl Drop for Reservation {
    fn drop(&mut self) {
        self.budget.external.fetch_sub(self.size, Ordering::SeqCst);
    }
}

unsafe extern "C" fn check_total(mut raw: v8::UnsafeRawIsolatePtr, data: *mut c_void) {
    // SAFETY: check() passes the allocator-owned Arc pointer. V8 does not run
    // pending isolate interrupts after its allocator has been destroyed.
    let budget = unsafe { &*(data as *const Budget) };
    // SAFETY: V8 calls this function on the owning isolate thread.
    let isolate = unsafe { v8::Isolate::ref_from_raw_isolate_ptr_mut(&mut raw) };
    budget.check_now(isolate);
}
fn layout(size: usize) -> Option<Layout> {
    Layout::from_size_align(size.max(1), 8).ok()
}
unsafe extern "C" fn allocate(budget: &Budget, size: usize) -> *mut c_void {
    allocate_buffer(budget, size, true)
}
unsafe extern "C" fn allocate_uninitialized(budget: &Budget, size: usize) -> *mut c_void {
    allocate_buffer(budget, size, false)
}
fn allocate_buffer(budget: &Budget, size: usize, zeroed: bool) -> *mut c_void {
    let Some(layout) = layout(size) else {
        budget.control.terminate(TERMINATION_HEAP);
        return ptr::null_mut();
    };
    if !budget.reserve(size) {
        return ptr::null_mut();
    }
    // SAFETY: The layout is nonzero with valid alignment. free() receives the
    // same byte length from V8 and reconstructs this exact layout.
    let allocation = unsafe {
        if zeroed {
            alloc_zeroed(layout)
        } else {
            alloc(layout)
        }
    };
    if allocation.is_null() {
        budget.external.fetch_sub(size, Ordering::SeqCst);
        budget.control.terminate(TERMINATION_HEAP);
    }
    allocation.cast()
}
unsafe extern "C" fn free(budget: &Budget, data: *mut c_void, size: usize) {
    if !data.is_null() {
        // SAFETY: Only pointers from allocate_buffer reach this V8 allocator.
        unsafe {
            dealloc(data.cast(), layout(size).expect("valid allocated layout"));
        }
        budget.external.fetch_sub(size, Ordering::SeqCst);
    }
}
unsafe extern "C" fn drop_budget(pointer: *const Budget) {
    // SAFETY: allocator() transfers exactly one Arc reference to V8.
    unsafe {
        drop(Arc::from_raw(pointer));
    }
}
