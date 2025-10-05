# libipc

This library defines the IPC API for SOS. This includes a struct defining an IPC message, and a serialiser and deserialiser.

Additionally, this library contains the logic for allocating and deallocating a shared frame between SOS and the client that may be used to transfer large data necessary for system calls, e.g. file names for `sos_open()`.
