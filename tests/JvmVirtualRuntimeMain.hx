import crossbyte.core.CrossByte;
import crossbyte.core.MainLoopType;
import crossbyte.core._internal.jvm.VirtualRuntimeThread;
import crossbyte.events.Event;
import crossbyte.utils.LogLevel;
import crossbyte.utils.Logger;
import haxe.EntryPoint;
import crossbyte.http.HTTPServer;
import crossbyte.http.HTTPServerConfig;
import sys.net.Host;
import sys.net.Socket;
import sys.thread.Lock;
import sys.thread.Tls;

/** Real JVM threads, timers, posts, ownership and process-lifetime checks. */
@:access(crossbyte.core.CrossByte)
@:access(haxe.EntryPoint)
class JvmVirtualRuntimeMain {
	static var expected:Bool = #if crossbyte_jvm_virtual_threads true #else false #end;
	static var checks = 0;

	static function check(condition:Bool, message:String):Void {
		checks++;
		if (!condition) throw new haxe.Exception(message);
	}

	static function wait(lock:Lock, message:String):Void {
		check(lock.wait(5), message);
	}

	static function count():Int {
		EntryPoint.mutex.acquire();
		var value = EntryPoint.threadCount;
		EntryPoint.mutex.release();
		return value;
	}

	static function settled():Void {
		var deadline = haxe.Timer.stamp() + 5;
		while (count() != 0 && haxe.Timer.stamp() < deadline) crossbyte.sys.System.sleep(0.005);
		check(count() == 0, "runtime leaked EntryPoint.threadCount");
	}

	static function http():Void {
		var ready = new Lock();
		var exited = new Lock();
		var server:HTTPServer = null;
		var owner:CrossByte = null;
		var failure:Dynamic = null;
		var child = CrossByte.make(POLL, HEAP, runtime -> {
			owner = runtime;
			runtime.addEventListener(Event.EXIT, _ -> exited.release());
			runtime.addEventListener(Event.INIT, _ -> {
				try {
					var config = new HTTPServerConfig("127.0.0.1", 0);
					config.http2Enabled = false;
					config.rateLimitKey = _ -> null;
					config.middleware = [(handler, next) -> {
						handler.respond(200, "text/plain", "virtual=" + VirtualRuntimeThread.isCurrentVirtual()
							+ ";owner=" + (CrossByte.current() == owner),
							[new crossbyte.url.URLRequestHeader("Connection", "keep-alive")]);
					}];
					server = new HTTPServer(config);
				} catch (error:Dynamic) { failure = error; }
				ready.release();
			});
		});
		wait(ready, "HTTP runtime did not initialize");
		var socket = new Socket();
		socket.setTimeout(3);
		try {
			if (failure != null) throw new haxe.Exception(Std.string(failure));
			socket.connect(new Host("127.0.0.1"), server.localPort);
			for (_ in 0...2) {
				socket.output.writeString("GET /probe HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n");
				socket.output.flush();
				var status = StringTools.trim(socket.input.readLine());
				check(status.indexOf("200") >= 0, "HTTP request failed");
				var length = -1;
				while (true) {
					var header = StringTools.trim(socket.input.readLine());
					if (header == "") break;
					if (StringTools.startsWith(header.toLowerCase(), "content-length:"))
						length = Std.parseInt(StringTools.trim(header.substr(15)));
				}
				check(length > 0 && length < 1024, "invalid HTTP response framing");
				check(socket.input.read(length).toString() == "virtual=" + expected + ";owner=true",
					"socket I/O was not handled on the expected runtime thread");
			}
		} catch (error:Dynamic) { failure = error; }
		socket.close();
		child.post(() -> {
			if (server != null) server.close();
			child.exit();
		});
		wait(exited, "HTTP runtime did not exit");
		settled();
		if (failure != null) throw new haxe.Exception(Std.string(failure));
	}

	public static function main():Void {
		EntryPoint.runInMainThread(() -> {});
		Logger.level = LogLevel.OFF;
		var root = new CrossByte(true, DEFAULT, true);
		check(!VirtualRuntimeThread.isCurrentVirtual(), "primordial thread changed");
		if (Sys.args().indexOf("--liveness") >= 0) {
			// Return from main without a join: the child must retain the JVM
			// until its timer runs, even though virtual threads are daemons.
			CrossByte.make(POLL, HEAP, child -> child.addEventListener(Event.INIT, _ -> {
				check(VirtualRuntimeThread.isCurrentVirtual() == expected, "wrong liveness thread type");
				crossbyte.Timer.setTimeout(0.1, () -> {
					Sys.println("VIRTUAL_RUNTIME_LIVENESS_OK");
					child.exit();
				});
			}));
			return;
		}

		var local = new Tls<String>();
		local.value = "parent";
		for (loop in [MainLoopType.DEFAULT, MainLoopType.POLL]) {
			var ready = new Lock();
			var posted = new Lock();
			var timed = new Lock();
			var exited = new Lock();
			var actual:Null<Bool> = null;
			var owned = false;
			var isolated = false;
			var timerOwned = false;
			var child = CrossByte.make(loop, HEAP, runtime -> {
				runtime.addEventListener(Event.INIT, _ -> {
					actual = VirtualRuntimeThread.isCurrentVirtual();
					owned = CrossByte.current() == runtime && runtime.__isOwnThread();
					isolated = local.value == null;
					local.value = "child";
					ready.release();
				});
				runtime.addEventListener(Event.EXIT, _ -> exited.release());
			});
			wait(ready, "runtime INIT timed out");
			check(actual == expected, "runtime is not using the requested JVM thread type");
			check(owned && isolated && local.value == "parent", "runtime ownership or TLS isolation failed");
			check(child.post(() -> {
				owned = CrossByte.current() == child && VirtualRuntimeThread.isCurrentVirtual() == expected;
				crossbyte.Timer.setTimeout(0.01, () -> {
					timerOwned = CrossByte.current() == child && local.value == "child";
					timed.release();
				});
				posted.release();
			}), "post rejected by a live runtime");
			wait(posted, "runtime post timed out");
			wait(timed, "runtime timer timed out");
			check(owned && timerOwned, "post or timer lost its runtime");
			child.exit();
			wait(exited, "runtime EXIT timed out");
			settled();
			check(!child.post(() -> {}), "exited runtime accepted work");
		}

		var initialized = false;
		var neverStarted = CrossByte.make(DEFAULT, HEAP, runtime -> {
			runtime.addEventListener(Event.INIT, _ -> initialized = true);
			runtime.exit();
		});
		check(!initialized && !neverStarted.__getRunning(), "configure-time exit started a runtime");
		settled();

		var failed = new Lock();
		var rejected = CrossByte.make(POLL, HEAP, runtime -> {
			runtime.addEventListener(Event.INIT, _ -> throw "intentional init failure");
			runtime.addEventListener(Event.EXIT, _ -> failed.release());
		});
		wait(failed, "failed INIT did not exit");
		check(!rejected.__getRunning(), "failed INIT kept running");
		settled();

		var parent = new CrossByte(false, DEFAULT, true);
		var stopped = new Lock();
		CrossByte.make(POLL, HEAP, runtime -> runtime.addEventListener(Event.EXIT, _ -> stopped.release()));
		parent.exit();
		wait(stopped, "child outlived its parent");
		settled();
		check(CrossByte.current() == root, "primordial runtime ownership was not restored");
		http();
		root.exit();
		Sys.println("VIRTUAL_RUNTIME_CHECKS_OK " + checks + " virtual=" + expected);
	}
}
