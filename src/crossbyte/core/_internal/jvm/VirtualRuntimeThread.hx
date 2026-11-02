package crossbyte.core._internal.jvm;

#if (jvm && !macro)
import haxe.EntryPoint;
import java.lang.Runnable;

/** Starts a Java 21 virtual runtime while preserving Haxe process lifetime. */
@:noCompletion
@:access(haxe.EntryPoint)
class VirtualRuntimeThread {
	public static function add(job:Void->Void):Void {
		// Virtual threads are daemon threads. Keep Haxe's main event loop
		// alive exactly as EntryPoint.addThread does for a platform thread.
		var events = EntryPoint.mainThread.events;
		events.promise();
		EntryPoint.mutex.acquire();
		EntryPoint.threadCount++;
		EntryPoint.mutex.release();

		var finished = false;
		var finish = () -> {
			// Also covers a start failure. Synchronize the one-time release so
			// a completion racing the start call can never release twice.
			EntryPoint.mutex.acquire();
			if (finished) {
				EntryPoint.mutex.release();
				return;
			}
			finished = true;
			EntryPoint.threadCount--;
			if (EntryPoint.threadCount == 0) EntryPoint.wakeup();
			EntryPoint.mutex.release();
			events.runPromised(() -> {});
		};

		var run:Runnable = () -> {
			try {
				job();
			} catch (error:Dynamic) {
				finish();
				throw error;
			}
			finish();
		};
		try {
			var thread = JavaThread21.ofVirtual().unstarted(run);
			thread.setName("crossbyte-runtime");
			thread.start();
		} catch (error:Dynamic) {
			finish();
			throw error;
		}
	}

	public static inline function isCurrentVirtual():Bool {
		return JavaThread21.currentThread().isVirtual();
	}
}

@:native("java.lang.Thread")
private extern class JavaThread21 {
	public static function ofVirtual():VirtualBuilder;
	public static function currentThread():JavaThread21;
	public function isVirtual():Bool;
}

@:native("java.lang.Thread$Builder$OfVirtual")
private extern interface VirtualBuilder {
	public function unstarted(task:Runnable):java.lang.Thread;
}
#end
