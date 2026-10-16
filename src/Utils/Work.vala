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

/** Carries a coroutine's resume callback across something that cannot
 *  reach the coroutine: a worker job, or a signal handler that runs
 *  before the coroutine continues. Delegates cannot be copied in Vala,
 *  so the holder is an object and the callback is only read back on the
 *  main context. */
internal class IdleResume : GLib.Object {
    private SourceFunc? callback;

    public IdleResume (owned SourceFunc callback) {
        this.callback = (owned) callback;
    }

    /** Resumes the coroutine on the main context. */
    public void resume_now () {
        Idle.add (on_idle);
    }

    private bool on_idle () {
        if (callback == null) {
            return Source.REMOVE;
        }
        callback ();
        callback = null;
        return Source.REMOVE;
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

    /** Runs `job` on a worker thread and resumes the calling coroutine
     *  on the main context when it finishes. Both delegates are passed
     *  as arguments: capturing a coroutine callback inside the job
     *  closure would have to copy a delegate, which Vala cannot do. */
    public static void submit_with_resume (owned WorkJob job, owned SourceFunc callback) {
        var resume = new IdleResume ((owned) callback);
        submit (() => {
            job ();
            resume.resume_now ();
        });
    }
}
}
