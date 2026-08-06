// Does the shim reproduce libstdc++'s random_shuffle permutation exactly?
// Compile on a Linux/libstdc++ host at C++14 (where the real one still exists)
// and compare both against the same seed.
#include <cstdio>
#include <cstdlib>
#include <vector>
#include <algorithm>
#include "random_shuffle_compat.h"

int main()
{
    for (int seed : {1, 42, 100, 7}) {
        std::vector<int> a(20), b(20);
        for (int i = 0; i < 20; ++i) { a[i] = i; b[i] = i; }

        srand(seed);
        displace_compat::random_shuffle(a.begin(), a.end());

#if __cplusplus < 201703L
        srand(seed);
        std::random_shuffle(b.begin(), b.end());
        bool same = (a == b);
        printf("seed %3d: shim==std ? %s\n", seed, same ? "YES" : "NO");
        if (!same) {
            printf("  shim:");
            for (int v : a) printf(" %d", v);
            printf("\n  std :");
            for (int v : b) printf(" %d", v);
            printf("\n");
        }
#else
        printf("seed %3d shim:", seed);
        for (int v : a) printf(" %d", v);
        printf("\n");
#endif
    }
    return 0;
}
