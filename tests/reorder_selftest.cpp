/* Headless guard for src/sta/Reorder.h - the Block Ack receive reorder
 * buffer.
 *
 * Each frame here is one byte: its own sequence number's low byte, so the
 * release order can be read straight off the output. What must hold: frames
 * leave in sequence order; a hole holds back everything behind it until the
 * window slides, a BlockAckReq moves it, or the hold time runs out; nothing
 * is released twice; the sequence space wraps at 4096. */
#include <cstdio>
#include <vector>

#include "sta/Reorder.h"

namespace {

using devourer::sta::RxReorder;

int g_fail = 0;

void check(bool ok, const char* what) {
  if (!ok) {
    std::printf("FAIL: %s\n", what);
    g_fail++;
  }
}

struct Sink {
  std::vector<int> out;
  void operator()(const uint8_t* f, size_t n) {
    out.push_back(n == 1 ? f[0] : -1);
  }
};

void push(RxReorder& r, Sink& s, uint16_t seq, uint32_t now = 0) {
  const uint8_t b = (uint8_t)seq;
  r.push(seq, &b, 1, now, s);
}

void test_in_order_passes_straight_through() {
  RxReorder r;
  Sink s;
  r.start(100, 8);
  for (uint16_t q = 100; q < 105; ++q) push(r, s, q);
  check(s.out == std::vector<int>({100, 101, 102, 103, 104}),
        "in order: each frame leaves as it arrives");
  check(r.held() == 0 && r.head() == 105, "in order: nothing held");
}

void test_a_hole_holds_back_then_fills() {
  RxReorder r;
  Sink s;
  r.start(10, 8);
  push(r, s, 10);
  push(r, s, 12);
  push(r, s, 13);
  check(s.out == std::vector<int>({10}), "hole: 12 and 13 wait for 11");
  check(r.held() == 2, "hole: ...held");
  push(r, s, 11);
  check(s.out == std::vector<int>({10, 11, 12, 13}),
        "hole: 11 arrives and all three leave in order");
}

void test_duplicates_and_old_frames_are_dropped() {
  RxReorder r;
  Sink s;
  r.start(10, 8);
  push(r, s, 10);
  push(r, s, 12);
  push(r, s, 12);
  push(r, s, 10);
  push(r, s, 9);
  check(s.out == std::vector<int>({10}), "dup: nothing extra released");
  check(r.dropped_dup == 1, "dup: the held copy is a duplicate");
  check(r.dropped_old == 2, "dup: frames before the window are old");
}

void test_beyond_the_window_slides_it() {
  RxReorder r;
  Sink s;
  r.start(0, 4);
  push(r, s, 1);
  push(r, s, 2);
  push(r, s, 6);  /* window 0..3 must move to 3..6 */
  check(s.out == std::vector<int>({1, 2}),
        "slide: the AP gave up on 0; 1 and 2 leave, 6 waits");
  check(r.head() == 3 && r.skipped == 1, "slide: ...head at 3, one hole");
  push(r, s, 3);
  push(r, s, 4);
  push(r, s, 5);
  check(s.out == std::vector<int>({1, 2, 3, 4, 5, 6}),
        "slide: the rest fills in order");
}

void test_bar_moves_the_window() {
  RxReorder r;
  Sink s;
  r.start(50, 8);
  push(r, s, 52);
  push(r, s, 54);
  r.bar(53, s);
  check(s.out == std::vector<int>({52}),
        "bar: everything before 53 leaves, holes skipped");
  check(r.head() == 53, "bar: ...the window starts at 53");
  r.bar(40, s);
  check(r.head() == 53, "bar: a BAR behind the window changes nothing");
  push(r, s, 53);
  check(s.out == std::vector<int>({52, 53, 54}), "bar: then in order again");
}

void test_timeout_releases_a_stuck_hole() {
  RxReorder r;
  Sink s;
  r.start(0, 16);
  push(r, s, 2, 100); /* 0 and 1 lost for good */
  push(r, s, 4, 150);
  r.timeout(180, 100, s);
  check(s.out.empty(), "timeout: nothing before the hold time");
  r.timeout(200, 100, s);
  check(s.out == std::vector<int>({2}),
        "timeout: 2 has waited 100 ms; 0 and 1 are given up");
  check(r.head() == 3, "timeout: ...4 still waits for 3");
  r.timeout(250, 100, s);
  check(s.out == std::vector<int>({2, 4}), "timeout: and then 4");

  /* A LATER slot can hold the OLDER frame. */
  RxReorder q;
  Sink t;
  q.start(0, 16);
  push(q, t, 5, 0);
  push(q, t, 2, 90);
  q.timeout(100, 100, t);
  check(t.out == std::vector<int>({2, 5}),
        "timeout: an old frame at slot 5 releases 2 with it, in order");
}

void test_the_sequence_space_wraps() {
  RxReorder r;
  Sink s;
  r.start(4094, 8);
  push(r, s, 4095);
  push(r, s, 0);
  push(r, s, 4094);
  push(r, s, 1);
  check(s.out == std::vector<int>({4094 & 0xff, 4095 & 0xff, 0, 1}),
        "wrap: 4094, 4095, 0, 1 in order");
  check(r.head() == 2, "wrap: head at 2");
  push(r, s, 4093);
  check(r.dropped_old == 1, "wrap: 4093 is behind the window, not ahead");
}

void test_stop_releases_what_is_held() {
  RxReorder r;
  Sink s;
  r.start(0, 8);
  push(r, s, 1);
  push(r, s, 3);
  r.stop(s);
  check(s.out == std::vector<int>({1, 3}), "stop: held frames leave in order");
  check(!r.active() && r.held() == 0, "stop: ...and the agreement is gone");
  check(r.skipped == 0, "stop: empty slots are not counted as skipped holes");
}

}  // namespace

int main() {
  test_in_order_passes_straight_through();
  test_a_hole_holds_back_then_fills();
  test_duplicates_and_old_frames_are_dropped();
  test_beyond_the_window_slides_it();
  test_bar_moves_the_window();
  test_timeout_releases_a_stuck_hole();
  test_the_sequence_space_wraps();
  test_stop_releases_what_is_held();
  if (g_fail) {
    std::printf("reorder_selftest: %d failure(s)\n", g_fail);
    return 1;
  }
  std::printf("reorder_selftest: OK\n");
  return 0;
}
