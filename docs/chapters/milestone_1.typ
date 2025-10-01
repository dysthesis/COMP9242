= Timer driver

The timer driver is responsible for managing timeouts. That is, user-land code needs to be able to define a time innterval and a callback function, and have that callback function executed after the given interval has elapsed.

We achieve this by registering a timeout on the timer device in the OdroidC2's S905 SOC. This is done by defining a counter $n$, a timebase $b$, and a callback function. This will result in the callback function being triggered after $n$ iterations of $b$ has elapsed. For instance, if we set $n = 100$ and $b = "ms"$, then the callback function will be triggered after 100 miliseconds.

== Challenge

The primary challenge for this therefore becomes the limited register size for the counter. For instance, Timer A has a counter size of 16 bits, which means that the maximum counter value is $65535$.
