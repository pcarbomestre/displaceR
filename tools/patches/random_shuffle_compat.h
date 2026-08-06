// Compatibility shim for std::random_shuffle, removed in C++17.
//
// DISPLACE needs C++17 for std::shared_mutex (include/Population.h:392) but
// still calls std::random_shuffle, which C++17 removed. libstdc++ and MSVC
// keep it available, so Linux and Windows build; libc++ does not, so macOS
// cannot build at any standard level.
//
// The obvious fix -- std::shuffle with an mt19937 -- would NOT be faithful.
// SimModel::initRandom() seeds the *global* rand() with srand(a_seed), derived
// from the digits in the simulation name, and every other stochastic decision
// in the simulator draws from that same rand(). Switching these call sites to a
// separate generator would decouple them from the seed and change results.
//
// So this reproduces the historical libstdc++ implementation exactly: the same
// backwards iteration, the same `rand() % (i + 1)` index, the same swap. Given
// an identical seed it performs an identical permutation, so a binary built
// with this shim yields the same results as one built against libstdc++'s
// extension.
//
// Reference: libstdc++ bits/stl_algo.h, __gnu_cxx::random_shuffle / the
// two-argument std::random_shuffle overload, which uses std::rand().

#ifndef DISPLACE_RANDOM_SHUFFLE_COMPAT_H
#define DISPLACE_RANDOM_SHUFFLE_COMPAT_H

// <algorithm> for std::iter_swap. It must be included explicitly: this header
// is inserted before every other include in the translation unit, so it cannot
// rely on anything else having pulled it in transitively.
#include <algorithm>
#include <cstdlib>
#include <iterator>
#include <utility>

namespace displace_compat {

template <typename RandomAccessIterator>
inline void random_shuffle(RandomAccessIterator first, RandomAccessIterator last)
{
    if (first == last) {
        return;
    }
    typedef typename std::iterator_traits<RandomAccessIterator>::difference_type diff_t;
    for (RandomAccessIterator i = first + 1; i != last; ++i) {
        // Historical libstdc++: swap *i with a uniformly chosen element in
        // [first, i]. std::rand() is the source, so srand() still controls it.
        diff_t offset = static_cast<diff_t>(std::rand() % ((i - first) + 1));
        RandomAccessIterator j = first + offset;
        if (i != j) {
            std::iter_swap(i, j);
        }
    }
}

} // namespace displace_compat

#endif // DISPLACE_RANDOM_SHUFFLE_COMPAT_H
