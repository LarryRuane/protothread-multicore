## Introduction ##

[Protothreads](http://en.wikipedia.org/wiki/Protothreads) is a programming model invented by Adam Dunkels that combines the advantages of _event-driven_ (sometimes also called _state machine_) programming and _threaded_ programming. The main advantage of the event-driven model is efficiency, both speed and memory usage. The main advantage of the threaded model is [algorithm clarity](http://dunkels.com/adam/dunkels06protothreads.pdf). Protothreads gives you both. A protothread is an extremely lightweight thread. As with event-driven programming, there is a single stack; but like threaded programming, a function can (at least conceptually) block. This protothreads implementation:
  * is not an implementation of POSIX threads (pthreads) or any other standard API
  * does not require assembly-language code or use setjmp/longjmp
  * is independent of CPU architecture

The version described here is a fork of the [Protothread](https://github.com/LarryRuane/protothread) repository, which does not support a multicore programming environment; this implementation does. It is standard C except for its use of [gcc label variables](http://gcc.gnu.org/onlinedocs/gcc/Labels-as-Values.html). It also depends on the `gcc pthread` library. Other than those dependencies, it can run without an operation system.

This project includes:
  * full source code (about 400 lines including comments)
  * two synchronization facilities built on top of the base protothreads (semaphores and locks)
  * about 800 lines of test code
  * gdb (debugger) macros to print the stack traces of a given protothread or all protothreads.

## Threads without stacks ##

The key concept of any protothreads implementation is that when a function wants to wait for an event to occur (that is, suspend itself and let other threads run), it saves its current location within the function (conceptually its line number or program counter), and returns back to the scheduler or idle loop, releasing use of the stack. The scheduler runs a different thread, handles interrupts or waits for an external event to occur. When the event occurs, the scheduler calls the function in the usual way, and the first thing the function does is `goto` the previously saved location. This location might be within levels of nested loops and `if` statements.

The `return` and `goto` statements are hidden within macros, so the application code looks very much like regular threaded code. This implementation uses a little-known gcc feature that lets you store the address of a `goto` label in a variable, and then later `goto` that variable (from within the same function), even if the function has returned and is now being called again. The performance is about the same as event-drive software; a context switch is just a few simple C statements.

You can think of protothreads as a generalization of event-driven programming. An event-driven work item (request in progress) typically consists of a pointer to a function (or a _state_ variable when using a big `switch` statement instead of individual functions) and a _context_ structure. These encapsulate the current state of the work item. A protothread has not just a function pointer (and context), but also a location _within_ the function. That location encodes a more fine-grain form of state than a simple function address. Actually, a protothread is even more general; if function **A** calls function **B**, **B** calls **C** and **C** blocks, then the thread now has a set of _three_ pointers into the middle of those functions.

## Support for multiple cores ##

Unlike other protothread implementations, this library allows multiple cores (processors) to run protothreads concurrently, thus taking advantage of those hardware resources. It uses the well-known technique of _pthread pools_. When the system is initialized (`protothread_create_maxpt(int)`), you specify a maximum number of pthreads that will be created to run protothreads. (Other pthreads can exist that are independent of the protothread system.) The number of protothreads can, and typically does, far exceed the number of pthreads. The protothreads are _multiplexed_ onto the pthreads.

When a protothread becomes ready to run, the protothread scheduler will assign it to an idle pthread to run if one is available; if not, and if the number of pthreads is below the maximum number, the scheduler will create a new pthread to run the protothread. If the number of pthreads is already at the maximum, the protothread will wait on a first-come-first-served queue until a pthread becomes available. For now, at least, the system never reduces the number of pthreads. If the maximum number of created pthreads is set to zero, the protothread system is single-threaded (only the initial thread runs protothreads), so there is the possibility of deterministic execution (more on this later).

Another reason to use this multicore version of protothread (even if there is a single core) is if protothreads sometimes block (in the kernel). In single-core protothread implementations, if a protothread blocks to read or write a disk file or a network socket, for example, the entire protothread system is blocked -- none of the protothreads can run. With this multicore implementation, a blocking protothread ties up a pthread, but otherwise does no harm. Other protothreads can run, either on existing pthreads or newly-created pthreads.

## Example - Producer / Consumer ##

Here is a protothreads version of the famous producer-consumer algorithm with two threads and a single shared integer mailbox. This is just to show the basic idea; details are explained later. All protothreads functions and types begin with `pt_` or (for "system level" entities) `protothread_`. Each thread needs a context structure:
```
/* main() needs to initialize using: pthread_mutex_init(&app_mutex, NULL) */
 pthread_mutex_t app_mutex ;

 typedef struct {
     pt_thread_t pt_thread;
     pt_func_t pt_func;
     int i;
     int * mailbox;
 } pc_thread_context_t;
```
Besides the first two fields, which are used by the protothreads system, the structure contains a counting index, `i`, and a pointer the mailbox that the threads will share. For the producer, the `i` is the next value to write to the mailbox; for the consumer, it's the next value to expect from the mailbox. A value of zero in the mailbox means it is empty.

Example 2 shows producer and consumer threads:
```
 static pt_t
 producer_thr(void * const env)
 {
     pc_thread_context_t * const c = env;
     pt_resume(c);
 
     for (c->i = 1; c->i <= 100; c->i++) {
         pthread_mutex_lock(&app_mutex) ;
         while (*c->mailbox) {
             /* mailbox is full */
             pt_wait(c, c->mailbox, &app_mutex);
         }
         *c->mailbox = c->i;
         pthread_mutex_unlock(&app_mutex) ;
         pt_signal(pt_get_pt(c), c->mailbox);
     }
     return PT_DONE;
 }
 
 static pt_t
 consumer_thr(void * const env)
 {
     pc_thread_context_t * const c = env;
     pt_resume(c);
 
     for (c->i = 1; c->i <= 100; c->i++) {
         pthread_mutex_lock(&app_mutex) ;
         while (*c->mailbox == 0) {
             /* mailbox is empty */
             pt_wait(c, c->mailbox, &app_mutex);
         }
         assert(*c->mailbox == c->i);
         *c->mailbox = 0;
         pthread_mutex_unlock(&app_mutex) ;
         pt_signal(pt_get_pt(c), c->mailbox);
     }
     return PT_DONE ;
 }
```
The producer thread waits until the mailbox is empty, then writes the next value to the mailbox and signals the consumer. The consumer thread waits until something appears in the mailbox, verifies that it's the expected value, writes a zero to signify that the mailbox is empty, and wakes up the producer. The threads signal each other using the address of the mailbox as the _channel_. It's common to use the address of the data structure whose state changes are of possible interest to waiting threads as the channel. In its role as a channel, the address is never dereferenced; it is strictly used to match signals with waits.

This technique of thread synchronization (and the term "channel") was first used in the UNIX kernel. The concept is similar to the _condition variable_ in POSIX threads -- there is no "memory" associated with the channel or a POSIX condition variable; signaling a channel or condition variable when no thread is waiting has no effect. The reason I choose to implement the channel approach is that it's simpler to use because it's not necessary to allocate condition variables. The API also includes `pt_broadcast()`, which is similar to `pt_signal()` except that it wakes up all threads waiting on the given channel, not just the longest-waiting thread.

The application mutex, `app_mutex`, is used to prevent lost signals, in the same manner as [pthread\_cond\_wait()](http://pubs.opengroup.org/onlinepubs/009695399/functions/pthread_cond_wait.html). Before testing the condition to be waited for, the application should acquire the mutex, so that if another protothread sets the condition to true just after the test, the waiting thread will be awakened.

The main test function allocates the overall protothread object or instance (`pt`) and a context for each thread, initializes the mailbox to empty, creates the threads, and runs the protothread system until there is no more work to do:
```
 static void
 test_pc(void)
 {
     /* maximum pthreads is 1 (could be 0 or greater) */
     protothread_t const pt = protothread_create_maxpt(1) ;
     pc_thread_context_t * const cc = malloc(sizeof(*cc));
     pc_thread_context_t * const pc = malloc(sizeof(*pc));
     int mailbox = 0;
 
     /* set up consumer context, start consumer thread */
     cc->mailbox = &mailbox;
     cc->i = 0;
     pt_create(pt, &cc->pt_thread, consumer_thr, cc);
 
     /* set up producer context, start producer thread */
     pc->mailbox = &mailbox;
     pc->i = 0;
     pt_create(pt, &pc->pt_thread, producer_thr, pc);
 
     /* wait for both protothreads to complete */
     protothread_quiesce(pt) ;
 
     /* threads have completed */
     assert(cc->i == 101);
     assert(pc->i == 101);
 
     free(cc);
     free(pc);
     protothread_free(pt);
 }
```
## How does it work? ##

Now for the details. The two most interesting calls in this example are `pt_resume()` and `pt_wait()`. Let's expand these in the producer thread function to see how they work. (The full API reference manual is given at the end of this article.) The `pt_func` member of the context structure contains the protothreads-private _function context_; the protothread macros access this field by name.
```
 static pt_t
 producer_thr(void * const env)
 {
     pc_thread_context_t * const c = env;
 
     /* pt_resume(c) expanded: *****/
     if ((c)->pt_func.label) goto *(c)->pt_func.label;
     /* pt_resume end *****/
 
     for (c->i = 1; c->i <= 100; c->i++) {
         pthread_mutex_lock(&app_mutex) ;
         while (*c->mailbox > 0) {
             /* mailbox is full */
 
             /* pt_wait(c, c->mailbox, &app_mutex) expanded: *****/
             do {
                 (c)->pt_func.label = &&pt_label_18;
                 pthread_mutex_lock(&(c)->pt_func.thread->s->mutex);
                 pthread_mutex_unlock(&app_mutex) ;
                 pt_enqueue_wait((c)->pt_func.thread, c->mailbox);
                 return PT_WAIT;
               pt_label_18:
                 pthread_mutex_lock(&app_mutex);
             } while (0);
             /* pt_wait() end *****/
         }
         *c->mailbox = c->i;
         pt_signal(pt_get_pt(c), c->mailbox);
         pthread_mutex_unlock(&app_mutex) ;
     }
     return PT_DONE;
 }
```
The first time the thread runs, its label variable is `NULL`, so it does not `goto` -- the code enters the `for` loop from the top. When it reaches the call to `pt_wait()`, it saves the address of the label (whose name is derived from the line number, `__LINE__`; note the double-ampersand syntax to denote the address corresponding to a label), enqueues the thread on a _waiting_ list within the protothreads object (and it's going to wait for a signal on the address of the mailbox), and returns `PT_WAIT`. (The return value is not used in this example; as explained later it is used only if there are nested protothread functions.)

When this thread is resumed, the label variable is non-NULL, so `pt_resume()` jumps to the value of the label variable, and execution continues from where it left off. In this case, the producer thread continues in the `while` loop, waiting for the mailbox to become empty. As when using POSIX condition variables, it's common to re-test the condition being waited for.

### Structure of a protothread ###

A protothread comprises one or more _protothread functions._ Only a protothread function can block or call a function that blocks. The overall protothread needs a `pt_thread_t` structure, which contains the protothread-private context for the thread. Furthermore, _each level_ of nested blocking function needs a user-defined context structure, and this structure must contain a `pt_func` member of type `pt_func_t`, which contains the protothread-private context for this function. If **A** calls **B** which in turn calls **C** (and **C** can block), each needs its own instance of a structure containing at least a `pt_func` member.

This structure also contains user-defined state that is specific to that function, usually what correspond to local variables when using POSIX threads. Protothread functions generally cannot use local variables, because their values are not preserved across waits. (You may have noticed the example uses `c->i` instead of `i` for the loop index.) There is one exception, however. It's common C coding practice to initialize a few local variables at their declarations (based on arguments) and use read-only as a convenience. You can use this technique with protothreads also (before the `pt_resume()`), as long as the initializations have no side effects. Example 2 does this with the context variable, `c`.

There are only two ways to run a protothread function; a protothread function should never be called directly.

  * Any code (a regular function or a protothread function) can call `pt_create()` to create a new thread. You specify a function address and a context pointer which is passed to the function as its only argument. This call schedules the thread (does not run it directly). There is no way to cancel a scheduled thread. The protothread system cannot notify you when a thread exits; that's up to you to arrange if you need to know. The `pt_create()` call also requires a unique (to this thread) `pt_thread_t` structure, which can be allocated anywhere, but is typically included within the top-level function's context structure (as in the structure `pc_thread_context_t` above).
  * A protothread function can execute `pt_call()`. This has the same semantics as a normal function call, but you must use `pt_call()` when calling a protothread function. Any number of arguments of any types may be passed to the called function (and the usual compiler type checking applies), but the first argument must be a pointer to a context structure (which contains a `pt_func` member) for the called function to use to hold its state.

Any return statements you write must return `PT_DONE`. Unfortunately, you cannot use the function return value for your own purposes, but you can return by argument reference and you can return values in the context structure. When the top-level protothread function returns, the thread has exited, and control returns to the scheduler.

### Protothread function nesting ###

How does function nesting work? When protothread function **A** calls (using `pt_call()`) a protothread function **B**, and **B** wants to block (`pt_wait()`), **B** saves its current location into its context and returns `PT_WAIT` to the `pt_call()` in **A**, which causes it to save into **A**'s context as its resume point exactly where it calls **B**. **A** then returns `PT_WAIT` to its caller. When the scheduler resumes the thread, **A** runs, its `pt_resume()` jumps to the call to **B**, so **A** calls **B**, and **B**'s `pt_resume()` jumps to just after where it had blocked and continues running. So the stack unwinds when the thread blocks, and "forward-winds" when it resumes. This is how the overall system still uses a single stack. Also, it should be clear now why evaluating the arguments that **A** passes to **B** should have no side effects -- **A** calls **B** every time the thread is resumed.

When **B** finally finishes and returns `PT_DONE`, **A** knows to continue running following the `pt_call()` to **B**.

The context for function **A** can include **B**'s context structure within its own, or it can dynamically allocate **B**'s context; allocation of contexts is up to the user. To provide greater data hiding, **A** can allocate a very small structure with just the required `pt_func` field and a pointer to an opaque (to **A**) **B** context. The first thing **B** does is dynamically allocate its full context structure and link it from the small context that **A** passed.

Another interesting idea is that if **A** calls **B** and after **B** returns **A** calls **C** (so **B** and **C** are not running at the same time), the contexts for **B** and **C** can be members of a `union` within **A**'s context. This sharing of memory between **B** and **C** reflects what happens within the stack of a POSIX thread.

## Deterministic execution ##

An important advantage of event-driven software over pthreads is that execution can be entirely deterministic. Protothreads shares this advantage. Why does this matter? Because it allows one to write pseudo-random tests that can reliably reproduce bugs. You start the test with a randomly-chosen random number generator seed, and if a bug is found during the run, you can start the test again with the same seed (perhaps with more tracing enabled or new assertions added to catch the problem earlier), and the test is guaranteed to follow exactly the same sequence of states and thus reproduce the bug. This also often allows you to verify a proposed fix (unless the fix changes the execution sequence in a way that invalidates the seed).

Of course, the entire environment must be carefully controlled so that no nondeterminism can sneak into the system. It may be necessary, for example, to simulate time; the code should not make any decisions based on real (wall-clock) time, because real time will differ from run to run. The random number generator should be used for anything that is non-deterministic in the real system (such as delays in simulated network or disk transfers).

Using POSIX threads makes it impossible to write a deterministic test, because the thread scheduler is out of the test program's control, and it makes random decisions (that vary from run to run).

In order for deterministic execution to be possible, the protothread system must be created with `max_pthread` set to 0. This means that the pthread that calls `pt_quiesce()` will run all protothreads (rather than waiting for other pthreads to finish running protothreads). This pthread is often the only (main) pthread. Your code will, of course, run more slowly; also, inter-thread mutex locking will not be exercised (there can't be any contention among pthreads, since there is only one pthread).

## Memory overhead and performance ##

The best known implementation of protothreads (by Adam Dunkels) uses just two bytes per protothread. This implementation is not quite so parsimonious (mainly because this implementation includes a scheduler: threads are on either the wait or run list); our environment is not as memory-constrained. Each protothread function context has a `pt_func_t` structure, which contains 2 pointers. Each overall protothread requires a `pt_thread_t` structure, which is 5 pointers. This is still extremely small compared to a POSIX thread.

The time to create and destroy a no-op thread on my desktop is 12.2 nanoseconds. The time to do that using POSIX pthreads is 7.85 microseconds, which is a ratio of 643. To compare context switch times, I timed the producer-consumer example, and each protothread switch took 22.2 nanoseconds. The context switch time for the same test coded in pthreads is 3.0 microseconds, for a ratio of 135.

If your application creates a very large number of prothreads (even millions), the system scales well, except you probably should change the definition of `PT_NWAIT` in `protothread.h`. This symbol determines the number of hash table buckets that implement the wait queue (of which there is one in the overall protothread system); the default value is `1 << 12` (4096). This requires memory equal to the size of a pointer times this value (on 64-bit systems, 32k bytes). For good performance, it should be the same order of magnitude as the number of protothreads in the system (or greater).

## Conclusion ##

For many resource-constrained or real-time applications, using protothreads gives far better performance and uses much less memory than POSIX threads. At the same time, algorithms can be expressed much more clearly using protothreads than using the event-driven model.

## API Reference ##

### Thread execution context ###

These are macros (designed to look and act like function calls) whose first argument is a pointer to a user-defined context structure, `c` (assume the context structure's name is `context_t`, but that is up the the user). The type `pt_f_t` is a pointer to a protothread function.

`void pt_resume(struct context_t *c)`
> Every thread function must call this macro first, after initializing any local variables (which must be a function only of the arguments and each other, not any global state). If the thread is being resumed, `pt_resume()` causes it to `goto` the resumption point, which is where this function last blocked. If the function is being called for the first time (that is, the thread is not being resumed), `pt_resume()` has no effect.

`void pt_wait(struct context_t *c, void *channel, pthread_mutex_t *mu)`
> Block until a signal is sent to the given channel. The channel is an arbitrary `void *` value which is usually chosen to be the address of a data structure whose state change the thread is interested. A channel itself has no state; the protothread system never uses the channel as an address (does not dereference it). Typically, after this function returns the condition being waited for is re-evaluated. Analogous to [POSIX pthread\_cond\_wait()](http://www.opengroup.org/onlinepubs/009695399/functions/pthread_cond_wait.html). The mutex must be locked (the usual practice is to lock before testing the condition that is being waited for), and `pt_wait` returns with it also locked.

`void pt_yield(struct context_t *c)`
> Reschedule the current thread and release the CPU. It is like `pt_wait()` on a channel that is immediately signaled. The current thread queues itself behind all ready to run threads and returns control to the scheduler.

`void pt_call(struct context_t *c, pt_f_t child_func, struct child_context_t *child_context, arg...)`
> Immediately call the given protothread function, passing it the given environment and arguments, and wait for it to return. There can be no context switch between the start of this statement and the start of the child function. Be careful that argument evaluation has no side effects, since this call occurs every time the thread is resumed. The usual C compile-time type checking is performed on all arguments.

`bool_t pt_call_waited(struct context_t *c)`
> Returns TRUE if the most recent `pt_call()` blocked (either directly in the called function, or in a function that it called, recursively). If function **A** calls **B** and **B** blocks, then when it finally returns to **A**, it's sometimes helpful for **A** to know that other threads might have run, so it should reevaluate the state of the world. But if **B** didn't block, then **A** knows that only a limited change of state (namely, whatever **B** might do) could have occurred.

`protothread_t pt_get_pt(struct context_t *c)`
> This returns the protothread object handle (`protothread_t`). It is a convenience that allows code in a thread context to call API functions that require a protothread object argument, such as `pt_create()` or `pt_signal()`.

### Either thread or non-thread execution context ###

`void pt_create(protothread_t, pt_thread_t, pt_f_t func, void *env)`
> Schedule the given protothread function to run, passing it the given environment. This function becomes the top-level function of the thread. There is no context break between this call and the caller's next statement. The new thread queues behind all ready threads. Analogous to [POSIX pthread\_create()](http://www.opengroup.org/onlinepubs/009695399/functions/pthread_create.html).

`void pt_broadcast(protothread_t, void *channel)`
> Send a signal to the given channel, which wakes up (schedules) all threads waiting on the channel to run in the same order they blocked. If there are no threads waiting, this call has no effect; the signal is not queued (there is no "memory" associated with a channel). These threads queue behind all ready threads. Analogous to [POSIX pthread\_cond\_broadcast()](http://www.opengroup.org/onlinepubs/009695399/functions/pthread_cond_broadcast.html).

`void pt_signal(protothread_t, void *channel)`
> Same as `pt_broadcast()` but wakes up only one (the oldest) waiting thread. Analogous to [POSIX pthread\_cond\_signal()](http://www.opengroup.org/onlinepubs/009695399/functions/pthread_cond_signal.html).

`protothread_t protothread_create(void)`
> This is usually only called once to create the overall protothread object. It returns the protothread handle. The protothread system uses no global variables. All protothread state is within this object; multiple protothread instances are independent. This is the only protothread API function that allocates memory. Equivalent to calling `protothread_create_maxpt(1)`.

`protothread_t protothread_create_maxpt(unsigned int max_pthread)`
> This is usually only called once to create the overall protothread object. It returns the protothread handle. The protothread system uses no global variables. All protothread state is within this object; multiple protothread instances are independent. This is the only protothread API function that allocates memory. Up to `max_pthread` pthreads will be created (on demand) during operation. (These are _additional_ pthreads; the original pthread is also able to run protothreads.)

`void protothread_free(protothread_t)`
> Free the state allocated with `protothread_create()`. There must be no threads associated with this object.

### Scheduling ###

`void protothread_quiesce(protothread_t)`
> Wait until all protothreads become idle (not running or ready to run). The application should use some mechanism outside of the protothread system to ensure that no protothreads become ready-to-run (either due to new protothread creation or protothreads transitioning from waiting to ready-to-run). If `max_pthread` was set to zero, calling this function will run the protothreads directly, returning only when there is nothing further to run (at the moment).

Please see `protothread_test.c` for working examples of using the library.

## References and Acknowledgements ##

[Wikipedia protothreads](http://en.wikipedia.org/wiki/Protothreads)

[POSIX thread reference](http://pubs.opengroup.org/onlinepubs/9699919799/basedefs/pthread.h.html)

I wish to gratefully acknowledge Adam Dunkels (with support from Oliver Schmidt) for inventing this brilliant idea. Please see his [web site](http://dunkels.com/adam/pt/).

My thanks to Paul Soulier for introducing me to the concept of protothreads, and to Marshall McMullen and John Rockenfeller for reviewing drafts of this article.

_LarryRuane@gmail.com_
