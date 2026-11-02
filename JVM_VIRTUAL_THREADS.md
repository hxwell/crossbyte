# JVM virtual runtime threads

This fork adds opt-in Java 21 virtual threads for child runtimes created with
`CrossByte.make`, including an HTTP server's listener and connection I/O runtime.
It is based on upstream commit `acc6de8994e0292ae48706017a2eafa4acbaedbf` so a
benchmark can compare the same Crossbyte implementation with one thread change.

```sh
haxe -lib crossbyte -lib hxjava -D crossbyte_jvm_virtual_threads \
  -main Main --jvm app.jar
java -jar app.jar
```

Without the define, child runtimes keep the upstream platform-thread behavior.
The define requires the JVM target and Java 21 or newer. The primordial host
thread remains host-owned. Socket polling and HTTP APIs are unchanged: this
switches each child runtime's owner thread, not the connection handling model.

The implementation uses `Thread.ofVirtual().unstarted(...)`, as HxWell's JVM
virtual-thread examples do. Crossbyte has its own small extern bridge and does
not depend on HxWell. Haxe's main-loop promise and thread counter are retained
until the runtime ends; a daemon virtual thread must not let the JVM terminate
while a child is still running. Both normal completion and start failures
release that accounting once.

Timer callbacks, `post`, runtime ownership and thread-local state continue to
belong to the child runtime. The tests query the actual Java thread type, send
two HTTP requests over one persistent socket, check startup failures and parent
shutdown, and test process lifetime by returning from `main` before a timer fires.

```sh
haxe ci/jvm-virtual-runtime.hxml
java -jar export/jvm/CrossByteVirtualRuntime.jar
java -jar export/jvm/CrossByteVirtualRuntime.jar --liveness
haxe ci/jvm-virtual-runtime.hxml -D crossbyte_jvm_virtual_threads
java -jar export/jvm/CrossByteVirtualRuntime.jar
java -jar export/jvm/CrossByteVirtualRuntime.jar --liveness
```

The HxWell benchmark keeps the upstream `jvm-crossbyte` case and adds a separate
fork case. HxWell already runs HTTP application handlers on virtual threads in
both cases; only the fork's child I/O runtime is virtual. The benchmark probes
that runtime during `/health` rather than inferring the result from a build flag.
