// libkoi: the client side of Koi's link to another machine, for the app.
// One link per machine carries independent streams, one per connection to
// that machine's server. See core/src/link.zig.
#ifndef KOI_H
#define KOI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct koi_link koi_link;
typedef struct koi_stream koi_stream;

/// Connects to the server's UDP port with the 32-byte secret its offer
/// carried, proving the path with a ping first; NULL if nothing answers
/// within a few seconds.
koi_link *koi_link_connect(const char *host, uint16_t port, const uint8_t secret[32]);

/// A new stream to the server; NULL once the link is closed.
koi_stream *koi_link_open(koi_link *link);

/// Whether the link has ended (closed, or the peer went silent).
int koi_link_closed(koi_link *link);

/// Ends the link: every stream's read returns 0.
void koi_link_close(koi_link *link);

/// Frees a closed link and any streams not yet released. Call only after
/// every thread using the link or its streams has returned.
void koi_link_destroy(koi_link *link);

/// Queues bytes; never blocks. A peer that falls 64 MiB behind has the stream
/// ended instead (reads return 0).
void koi_stream_send(koi_stream *stream, const uint8_t *bytes, size_t len);

/// Blocks until bytes arrive, returning how many were copied into `buf`;
/// 0 once the stream has ended.
size_t koi_stream_read(koi_stream *stream, uint8_t *buf, size_t cap);

/// Closes this side of the stream: pending reads return 0. Idempotent; the
/// stream stays valid for send/read/close until released.
void koi_stream_close(koi_stream *stream);

/// Gives the stream back to the link, closing it first. Call exactly once,
/// last, after every thread using the stream has stopped; the pointer is dead
/// afterwards. Without it the stream is only freed by koi_link_destroy.
void koi_stream_release(koi_stream *stream);

#ifdef __cplusplus
}
#endif

#endif
