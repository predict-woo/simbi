// C interface over vendored libwebm (mkvmuxer/mkvparser) for Simbi.
//
// Writer: live/streaming-mode WebM — no SeekHead, no Duration, every
// cluster has an unknown size. Nothing needs finalizing, so the file is
// valid after every flush (crash-tolerant) and appendable: a resumed
// session opens the file with swebm_writer_append and just writes more
// clusters (SPEC.md §3.1).
//
// Reader: parses the same files back — builds a cluster index (time →
// byte offset) for seeking and iterates Opus packets for decode.

#ifndef SIMBI_WEBM_SHIM_H
#define SIMBI_WEBM_SHIM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct swebm_writer swebm_writer;
typedef struct swebm_reader swebm_reader;
typedef struct swebm_iter swebm_iter;

// --- Writer ---------------------------------------------------------------

// Creates a new WebM file and writes the headers: EBML header, Segment
// (unknown size), Info (timecode scale 1ms), and one Opus audio track
// (track number 1) with the given CodecPrivate (OpusHead bytes).
// codec_delay_ns / seek_pre_roll_ns are the TrackEntry elements (Opus:
// encoder lookahead in ns / 80ms). Returns NULL on failure.
swebm_writer* swebm_writer_create(const char* path,
                                  const uint8_t* codec_private,
                                  size_t codec_private_len,
                                  double sample_rate_hz,
                                  uint64_t channels,
                                  uint64_t codec_delay_ns,
                                  uint64_t seek_pre_roll_ns);

// Opens an existing live-mode WebM file for appending further clusters.
// Writes no headers. Returns NULL on failure.
swebm_writer* swebm_writer_append(const char* path);

// Starts a new cluster at the given absolute timecode (milliseconds).
// Implicitly closes the current cluster, if any. Returns 0 on success.
int swebm_writer_begin_cluster(swebm_writer* w, uint64_t timecode_ms);

// Writes one Opus packet as a SimpleBlock in the current cluster.
// timecode_ms is absolute (not cluster-relative); it must be within
// ~32s of the cluster start (int16 relative timecode) — the caller
// rolls clusters long before that. Returns 0 on success.
int swebm_writer_add_frame(swebm_writer* w,
                           const uint8_t* data,
                           size_t len,
                           uint64_t timecode_ms);

// Flushes buffered bytes to disk (fflush). Returns 0 on success.
int swebm_writer_flush(swebm_writer* w);

// Closes the current cluster and the file, then frees the writer.
// Returns 0 on success. The writer is freed even on failure.
int swebm_writer_close(swebm_writer* w);

// --- Reader ---------------------------------------------------------------

// Opens a WebM file and scans all clusters (including unknown-size
// live-mode clusters), building the cluster index. Returns NULL on
// failure.
swebm_reader* swebm_reader_open(const char* path);

// Number of clusters in the file.
size_t swebm_reader_cluster_count(const swebm_reader* r);

// Info for cluster i: start time (ns) and byte offset of the cluster
// element in the file. Returns 0 on success, -1 if out of range.
int swebm_reader_cluster_info(const swebm_reader* r,
                              size_t i,
                              int64_t* time_ns,
                              int64_t* file_offset);

// End time of the last block in the file in ns (start time of the last
// block; block durations are not stored). Returns -1 if there are no
// blocks.
int64_t swebm_reader_last_block_time_ns(const swebm_reader* r);

void swebm_reader_close(swebm_reader* r);

// --- Block iteration --------------------------------------------------------

// Iterator over track-1 blocks, starting at the first cluster whose
// start time is <= start_time_ns (i.e. the seek target's cluster), or
// the first cluster if start_time_ns is 0. Returns NULL on failure.
swebm_iter* swebm_iter_create(swebm_reader* r, int64_t start_time_ns);

// Reads the next Opus packet. On success returns 1 and fills time_ns,
// out_len, and up to buf_cap bytes of buf. Returns 0 at end of file,
// -1 on parse error, -2 if the packet is larger than buf_cap (out_len
// is set to the required size; the iterator does not advance).
int swebm_iter_next(swebm_iter* it,
                    int64_t* time_ns,
                    uint8_t* buf,
                    size_t buf_cap,
                    size_t* out_len);

void swebm_iter_free(swebm_iter* it);

#ifdef __cplusplus
}
#endif

#endif  // SIMBI_WEBM_SHIM_H
