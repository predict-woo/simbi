// See webm_shim.h. C++ implementation over vendored libwebm.

#include "webm_shim.h"

#include <cstdio>
#include <cstring>
#include <new>
#include <vector>

#include "mkvmuxer/mkvmuxer.h"
#include "mkvmuxer/mkvmuxerutil.h"
#include "mkvparser/mkvparser.h"
#include "mkvparser/mkvreader.h"

namespace {

constexpr uint64_t kTimecodeScaleNs = 1000000;  // 1 ms
constexpr uint64_t kOpusTrackNumber = 1;

// Non-seekable FILE* writer. Reporting Seekable()=false keeps mkvmuxer
// in pure streaming behavior: no backpatching, unknown-size clusters.
class StreamWriter : public mkvmuxer::IMkvWriter {
 public:
  explicit StreamWriter(FILE* file) : file_(file) {}
  ~StreamWriter() override {
    if (file_) fclose(file_);
  }

  mkvmuxer::int32 Write(const void* buf, mkvmuxer::uint32 len) override {
    if (!file_) return -1;
    return fwrite(buf, 1, len, file_) == len ? 0 : -1;
  }
  mkvmuxer::int64 Position() const override { return ftello(file_); }
  mkvmuxer::int32 Position(mkvmuxer::int64) override { return -1; }
  bool Seekable() const override { return false; }
  void ElementStartNotify(mkvmuxer::uint64, mkvmuxer::int64) override {}

  int Flush() { return file_ && fflush(file_) == 0 ? 0 : -1; }

 private:
  FILE* file_;
};

}  // namespace

struct swebm_writer {
  StreamWriter* writer = nullptr;
  mkvmuxer::Cluster* cluster = nullptr;

  int CloseCluster() {
    if (!cluster) return 0;
    const bool ok = cluster->Finalize();
    delete cluster;
    cluster = nullptr;
    return ok ? 0 : -1;
  }
};

extern "C" {

swebm_writer* swebm_writer_create(const char* path,
                                  const uint8_t* codec_private,
                                  size_t codec_private_len,
                                  double sample_rate_hz,
                                  uint64_t channels,
                                  uint64_t codec_delay_ns,
                                  uint64_t seek_pre_roll_ns) {
  FILE* file = fopen(path, "wb");
  if (!file) return nullptr;
  auto* w = new (std::nothrow) swebm_writer;
  if (!w) {
    fclose(file);
    return nullptr;
  }
  w->writer = new StreamWriter(file);

  if (!mkvmuxer::WriteEbmlHeader(w->writer, 4, "webm")) goto fail;

  {
    // Segment element with unknown size (live mode: never patched).
    const uint8_t segment_header[] = {0x18, 0x53, 0x80, 0x67,  // Segment ID
                                      0x01, 0xFF, 0xFF, 0xFF,  // unknown size
                                      0xFF, 0xFF, 0xFF, 0xFF};
    if (w->writer->Write(segment_header, sizeof(segment_header)) != 0)
      goto fail;

    mkvmuxer::SegmentInfo info;
    if (!info.Init()) goto fail;
    info.set_timecode_scale(kTimecodeScaleNs);
    info.set_writing_app("Simbi");
    if (!info.Write(w->writer)) goto fail;

    mkvmuxer::Tracks tracks;
    unsigned int seed = 0x51B1;
    auto* track = new (std::nothrow) mkvmuxer::AudioTrack(&seed);
    if (!track) goto fail;
    track->set_number(kOpusTrackNumber);
    track->set_type(mkvmuxer::Tracks::kAudio);
    track->set_codec_id(mkvmuxer::Tracks::kOpusCodecId);
    track->set_sample_rate(sample_rate_hz);
    track->set_channels(channels);
    track->set_codec_delay(codec_delay_ns);
    track->set_seek_pre_roll(seek_pre_roll_ns);
    if (codec_private_len > 0 &&
        !track->SetCodecPrivate(codec_private, codec_private_len))
      goto fail;
    // Tracks takes ownership of |track|.
    if (!tracks.AddTrack(track, static_cast<int32_t>(kOpusTrackNumber)))
      goto fail;
    if (!tracks.Write(w->writer)) goto fail;
  }

  if (w->writer->Flush() != 0) goto fail;
  return w;

fail:
  delete w->writer;
  delete w;
  return nullptr;
}

swebm_writer* swebm_writer_append(const char* path) {
  FILE* file = fopen(path, "ab");
  if (!file) return nullptr;
  auto* w = new (std::nothrow) swebm_writer;
  if (!w) {
    fclose(file);
    return nullptr;
  }
  w->writer = new StreamWriter(file);
  return w;
}

int swebm_writer_begin_cluster(swebm_writer* w, uint64_t timecode_ms) {
  if (!w) return -1;
  if (w->CloseCluster() != 0) return -1;
  w->cluster = new (std::nothrow)
      mkvmuxer::Cluster(timecode_ms, /*cues_pos=*/-1, kTimecodeScaleNs);
  if (!w->cluster || !w->cluster->Init(w->writer)) {
    delete w->cluster;
    w->cluster = nullptr;
    return -1;
  }
  return 0;
}

int swebm_writer_add_frame(swebm_writer* w,
                           const uint8_t* data,
                           size_t len,
                           uint64_t timecode_ms) {
  if (!w || !w->cluster) return -1;
  // Despite its parameter name, Cluster::AddFrame wants the frame
  // timestamp in nanoseconds — WriteFrame divides by the timecode scale
  // before computing the cluster-relative timecode.
  return w->cluster->AddFrame(data, len, kOpusTrackNumber,
                              timecode_ms * kTimecodeScaleNs,
                              /*is_key=*/true)
             ? 0
             : -1;
}

int swebm_writer_flush(swebm_writer* w) {
  if (!w) return -1;
  return w->writer->Flush();
}

int swebm_writer_close(swebm_writer* w) {
  if (!w) return -1;
  int rc = w->CloseCluster();
  if (w->writer->Flush() != 0) rc = -1;
  delete w->writer;  // closes the FILE*
  delete w;
  return rc;
}

}  // extern "C"

// --- Reader -----------------------------------------------------------------

struct swebm_cluster_info {
  int64_t time_ns;
  int64_t offset;
};

struct swebm_reader {
  mkvparser::MkvReader reader;
  mkvparser::Segment* segment = nullptr;
  std::vector<swebm_cluster_info> clusters;
  int64_t last_block_time_ns = -1;

  ~swebm_reader() { delete segment; }
};

struct swebm_iter {
  swebm_reader* r;
  const mkvparser::Cluster* cluster;
  const mkvparser::BlockEntry* entry;
  // True when the current entry was returned as -2 (buffer too small)
  // and must be re-delivered on the next call instead of advancing.
  bool redeliver;
};

extern "C" {

swebm_reader* swebm_reader_open(const char* path) {
  auto* r = new (std::nothrow) swebm_reader;
  if (!r) return nullptr;
  if (r->reader.Open(path) != 0) {
    delete r;
    return nullptr;
  }

  long long pos = 0;
  mkvparser::EBMLHeader ebml;
  if (ebml.Parse(&r->reader, pos) != 0) {
    delete r;
    return nullptr;
  }

  if (mkvparser::Segment::CreateInstance(&r->reader, pos, r->segment) != 0 ||
      !r->segment) {
    delete r;
    return nullptr;
  }
  if (r->segment->ParseHeaders() != 0) {
    delete r;
    return nullptr;
  }

  // Incrementally load every cluster (required for unknown-size
  // live-mode clusters, which Segment::Load refuses to handle).
  for (;;) {
    long long parse_pos = 0;
    long parse_len = 0;
    const long status = r->segment->LoadCluster(parse_pos, parse_len);
    if (status < 0) {
      // Truncated trailing cluster (e.g. after a crash): keep everything
      // parsed so far and drop the tail (guide §10.3 step 1).
      break;
    }
    if (status != 0) break;  // 1 = reached end of segment
    // LoadCluster may return 0 without new clusters at EOF; detect by
    // comparing the count below.
    if (r->segment->GetCount() > 0 &&
        static_cast<size_t>(r->segment->GetCount()) == r->clusters.size())
      break;
    const mkvparser::Cluster* cluster =
        r->segment->GetLast();
    if (!cluster || cluster->EOS()) break;
    swebm_cluster_info info;
    info.time_ns = cluster->GetTime();
    info.offset = cluster->m_element_start;
    r->clusters.push_back(info);
  }

  // Find the last block time by walking the last cluster's entries.
  if (!r->clusters.empty()) {
    const mkvparser::Cluster* last = r->segment->GetLast();
    if (last && !last->EOS()) {
      const mkvparser::BlockEntry* entry = nullptr;
      long status = last->GetFirst(entry);
      while (status == 0 && entry && !entry->EOS()) {
        const mkvparser::Block* block = entry->GetBlock();
        if (block && block->GetTrackNumber() == kOpusTrackNumber)
          r->last_block_time_ns = block->GetTime(last);
        status = last->GetNext(entry, entry);
      }
    }
  }

  return r;
}

size_t swebm_reader_cluster_count(const swebm_reader* r) {
  return r ? r->clusters.size() : 0;
}

int swebm_reader_cluster_info(const swebm_reader* r,
                              size_t i,
                              int64_t* time_ns,
                              int64_t* file_offset) {
  if (!r || i >= r->clusters.size()) return -1;
  if (time_ns) *time_ns = r->clusters[i].time_ns;
  if (file_offset) *file_offset = r->clusters[i].offset;
  return 0;
}

int64_t swebm_reader_last_block_time_ns(const swebm_reader* r) {
  return r ? r->last_block_time_ns : -1;
}

void swebm_reader_close(swebm_reader* r) { delete r; }

swebm_iter* swebm_iter_create(swebm_reader* r, int64_t start_time_ns) {
  if (!r || !r->segment) return nullptr;
  const mkvparser::Cluster* cluster = r->segment->GetFirst();
  // Advance to the last cluster starting at or before the target time.
  while (cluster && !cluster->EOS()) {
    const mkvparser::Cluster* next = r->segment->GetNext(cluster);
    if (!next || next->EOS() || next->GetTime() > start_time_ns) break;
    cluster = next;
  }
  if (!cluster || cluster->EOS()) return nullptr;

  auto* it = new (std::nothrow) swebm_iter;
  if (!it) return nullptr;
  it->r = r;
  it->cluster = cluster;
  it->entry = nullptr;
  it->redeliver = false;
  return it;
}

int swebm_iter_next(swebm_iter* it,
                    int64_t* time_ns,
                    uint8_t* buf,
                    size_t buf_cap,
                    size_t* out_len) {
  if (!it) return -1;
  while (it->cluster && !it->cluster->EOS()) {
    if (!it->redeliver) {
      long status;
      if (!it->entry) {
        status = it->cluster->GetFirst(it->entry);
      } else {
        status = it->cluster->GetNext(it->entry, it->entry);
      }
      if (status < 0) return -1;
      if (!it->entry || it->entry->EOS()) {
        it->cluster = it->r->segment->GetNext(it->cluster);
        it->entry = nullptr;
        continue;
      }
    }
    it->redeliver = false;
    const mkvparser::Block* block = it->entry->GetBlock();
    if (!block || block->GetTrackNumber() != kOpusTrackNumber) continue;
    // Simbi writes one frame per SimpleBlock.
    const mkvparser::Block::Frame& frame = block->GetFrame(0);
    if (out_len) *out_len = static_cast<size_t>(frame.len);
    if (static_cast<size_t>(frame.len) > buf_cap) {
      it->redeliver = true;
      return -2;
    }
    if (frame.Read(&it->r->reader, buf) != 0) return -1;
    if (time_ns) *time_ns = block->GetTime(it->cluster);
    return 1;
  }
  return 0;
}

void swebm_iter_free(swebm_iter* it) { delete it; }

}  // extern "C"
