/* The receive reorder buffer of one Block Ack agreement (802.11-2016
 * 10.24.7), for one TID. Device-free like the rest of src/sta: frames go in
 * with their sequence number and a clock, and come out in sequence order
 * through a callback.
 *
 * WHY IT EXISTS. Inside an agreement the AP retransmits only the MPDUs of an
 * A-MPDU that the BlockAck bitmap said were lost, so a later frame can arrive
 * before an earlier one. CCMP's replay bitmap accepts that (CcmpReplay), but
 * the host would then see TCP segments out of order, which TCP reads as loss:
 * duplicate ACKs, fast retransmit, a halved window. The buffer hands frames
 * on in sequence order, before decryption, which is where mac80211 puts it.
 *
 * WHAT IT RELEASES, in order of preference:
 *  - the frame at the window start, and every consecutive one after it;
 *  - on a frame beyond the window, everything the window must slide past
 *    (the AP has given up on those, holes included);
 *  - on a BlockAckReq, everything before its starting sequence number;
 *  - on timeout, everything up to the oldest frame that has waited too long
 *    (a lost frame the AP will never send again would stall the TID).
 * A frame before the window, or one already held, is a duplicate: dropped
 * and counted. Holes are skipped, never invented.
 *
 * Not thread-safe: the caller serialises (the station client's g_mu). */
#ifndef DEVOURER_STA_REORDER_H
#define DEVOURER_STA_REORDER_H

#include <cstdint>
#include <vector>

namespace devourer {
namespace sta {

class RxReorder {
 public:
  static constexpr uint16_t kMaxWin = 64;
  static constexpr uint16_t kSeqMod = 4096;

  /* A new agreement: the window starts at `ssn` and holds `win` frames
   * (clamped to 1..kMaxWin). Anything still held from an earlier one is
   * dropped, not released: it belongs to a session the AP has ended. */
  void start(uint16_t ssn, uint16_t win) {
    clear();
    head_ = ssn & 0x0fff;
    win_ = win == 0 || win > kMaxWin ? kMaxWin : win;
    active_ = true;
  }

  /* The agreement ended (DELBA, leave). Held frames are released in order
   * first: they were received and authenticated by nobody yet, and the AP
   * considers them delivered. */
  template <class F>
  void stop(F&& release) {
    /* Released in order, but the empty slots are not holes given up on:
     * the AP ended the agreement, it did not lose those frames. */
    for (uint16_t i = 0; active_ && i < win_; ++i) {
      const uint16_t seq = (uint16_t)((head_ + i) & 0x0fff);
      Slot& s = slots_[seq % kMaxWin];
      if (s.used && s.seq == seq) emit(s, release);
    }
    clear();
  }

  bool active() const { return active_; }
  uint16_t head() const { return head_; }
  uint16_t window() const { return win_; }
  int held() const { return held_; }

  /* One received MPDU with sequence number `seq`. */
  template <class F>
  void push(uint16_t seq, const uint8_t* mpdu, size_t len, uint32_t now_ms,
            F&& release) {
    seq &= 0x0fff;
    const uint16_t d = dist(head_, seq);
    if (d >= kSeqMod / 2) { dropped_old++; return; }
    /* Beyond the window: slide it so `seq` is its last slot. */
    if (d >= win_) flush_until((uint16_t)((seq - win_ + 1) & 0x0fff), release);
    Slot& s = slots_[seq % kMaxWin];
    if (s.used) { dropped_dup++; return; }
    s.used = true;
    s.seq = seq;
    s.at_ms = now_ms;
    s.frame.assign(mpdu, mpdu + len);
    held_++;
    release_in_order(release);
  }

  /* A BlockAckReq: the AP will not send anything before `ssn` again. */
  template <class F>
  void bar(uint16_t ssn, F&& release) {
    ssn &= 0x0fff;
    if (!active_ || dist(head_, ssn) >= kSeqMod / 2) return;
    flush_until(ssn, release);
    release_in_order(release);
  }

  /* Release past any hole that has held a frame behind it for `hold_ms`:
   * everything up to the LAST held frame that has waited that long goes,
   * holes included. The last, not the first - frames arrive in any order,
   * so a later slot can hold an older frame. */
  template <class F>
  void timeout(uint32_t now_ms, uint32_t hold_ms, F&& release) {
    if (!active_ || held_ == 0) return;
    int last = -1;
    for (uint16_t i = 0; i < win_; ++i) {
      const uint16_t seq = (uint16_t)((head_ + i) & 0x0fff);
      const Slot& s = slots_[seq % kMaxWin];
      if (s.used && s.seq == seq &&
          (int32_t)(now_ms - s.at_ms) >= (int32_t)hold_ms)
        last = i;
    }
    if (last < 0) return;
    flush_until((uint16_t)((head_ + last + 1) & 0x0fff), release);
    release_in_order(release);
  }

  uint64_t dropped_old = 0;   /* before the window: a late retransmission */
  uint64_t dropped_dup = 0;   /* already held */
  uint64_t skipped = 0;       /* holes given up on (slide, BAR, timeout) */

 private:
  struct Slot {
    bool used = false;
    uint16_t seq = 0;
    uint32_t at_ms = 0;
    std::vector<uint8_t> frame;
  };

  static uint16_t dist(uint16_t from, uint16_t to) {
    return (uint16_t)((to - from) & 0x0fff);
  }

  void clear() {
    for (Slot& s : slots_) {
      s.used = false;
      s.frame.clear();
    }
    held_ = 0;
    active_ = false;
  }

  /* Release consecutive frames from the head. */
  template <class F>
  void release_in_order(F&& release) {
    for (;;) {
      Slot& s = slots_[head_ % kMaxWin];
      if (!s.used || s.seq != head_) return;
      emit(s, release);
      head_ = (uint16_t)((head_ + 1) & 0x0fff);
    }
  }

  /* Move the head to `to`, releasing what is held on the way and counting
   * the holes. */
  template <class F>
  void flush_until(uint16_t to, F&& release) {
    while (head_ != to) {
      Slot& s = slots_[head_ % kMaxWin];
      if (s.used && s.seq == head_) emit(s, release);
      else skipped++;
      head_ = (uint16_t)((head_ + 1) & 0x0fff);
    }
  }

  template <class F>
  void emit(Slot& s, F&& release) {
    std::vector<uint8_t> f;
    f.swap(s.frame);
    s.used = false;
    held_--;
    release(f.data(), f.size());
  }

  Slot slots_[kMaxWin];
  uint16_t head_ = 0;
  uint16_t win_ = kMaxWin;
  int held_ = 0;
  bool active_ = false;
};

}  // namespace sta
}  // namespace devourer

#endif /* DEVOURER_STA_REORDER_H */
