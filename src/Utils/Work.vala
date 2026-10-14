/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Off-main-thread helper.
 *
 * Runs blocking or CPU-bound work (JSON parsing, disk reads, image
 * decoding, base64) on a small bounded worker pool and resumes the
 * calling coroutine on the main context. Only touch widgets after
 * the coroutine resumes — never inside `submit`.
 */

namespace OpenClient {

/** A unit of background work. */
public delegate void WorkJob ();

/** Box for a closure crossing into the thread pool. */
class WorkJobHolder : GLib.Object {
    private WorkJob task;

    public WorkJobHolder (owned WorkJob task) {
        this.task = (owned) task;
    }

    public void run () {
        task ();
    }
}

public class Work : GLib.Object {
    private static GLib.ThreadPool<WorkJobHolder>? pool = null;

    /** Runs `job` on a worker thread (pool of 2). Falls back to the
     *  calling thread if the pool cannot be created. */
    public static void submit (owned WorkJob job) {
        if (pool == null) {
            try {
                pool = new GLib.ThreadPool<WorkJobHolder>.with_owned_data ((holder) => {
                    holder.run ();
                }, 2, false);
            } catch (ThreadError e) {
                warning ("Worker pool unavailable, running inline: %s", e.message);
                job ();
                return;
            }
        }
        try {
            pool.add (new WorkJobHolder ((owned) job));
        } catch (ThreadError e) {
            warning ("Worker pool full, running inline: %s", e.message);
            job ();
        }
    }

    /** Resumes a coroutine's `SourceFunc` on the main context. Safe to
     *  call from a worker thread. */
    public static void resume (owned SourceFunc callback) {
        Idle.add (() => {
            callback ();
            return false;
        });
    }
}

}
