/**
 * host_matmul.cpp — Host program for krnl_matmul hardware emulation
 *
 * Tests 32×32 FP32 matrix multiply: OUT = X × W^T
 *
 * Usage:
 *   # Build hw_emu xclbin first:  make hw_emu
 *   export XCL_EMULATION_MODE=hw_emu
 *   ./host_matmul -x krnl_matmul.hw_emu.xclbin
 *
 *   # For real hardware:  make build
 *   ./host_matmul -x krnl_matmul.hw.xclbin
 */

#include <iostream>
#include <iomanip>
#include <cstring>
#include <cmath>
#include <vector>
#include <random>
#include <chrono>
#include <unistd.h>

#include "xrt/xrt_bo.h"
#include "xrt/xrt_device.h"
#include "xrt/xrt_kernel.h"

static constexpr int N     = 32;
static constexpr int TOTAL = N * N;
static constexpr size_t MATRIX_BYTES = TOTAL * sizeof(float);

static void compute_ref(const float* W, const float* X, float* out) {
    for (int i = 0; i < N; i++)
        for (int j = 0; j < N; j++) {
            float sum = 0.0f;
            for (int k = 0; k < N; k++)
                sum += X[i*N+k] * W[j*N+k];   // OUT = X * W^T
            out[i*N+j] = sum;
        }
}

static bool matrices_close(const float* got, const float* exp,
                            float rtol = 1e-3f, float atol = 1e-5f) {
    for (int i = 0; i < TOTAL; i++) {
        float g = got[i], e = exp[i];
        float err = std::abs(g - e);
        float rel = (std::abs(e) > 1e-10f) ? err / std::abs(e) : err;
        if (rel > rtol && err > atol) {
            int r = i / N, c = i % N;
            std::cerr << "  MISMATCH [" << r << "][" << c << "]: "
                      << "got " << g << ", expected " << e
                      << " (rel " << rel << ")\n";
            return false;
        }
    }
    return true;
}

static void print_matrix(const char* name, const float* m) {
    std::cout << name << ":\n";
    for (int i = 0; i < N; i++) {
        std::cout << "  ";
        for (int j = 0; j < N; j++)
            std::cout << std::setw(10) << std::fixed << std::setprecision(3) << m[i*N+j];
        std::cout << "\n";
    }
}

static bool run_test(xrt::device& device, xrt::kernel& krnl, const char* label,
                     const float* W, const float* X, bool print_output = false) {
    auto bo_w   = xrt::bo(device, MATRIX_BYTES, krnl.group_id(0));
    auto bo_x   = xrt::bo(device, MATRIX_BYTES, krnl.group_id(1));
    auto bo_out = xrt::bo(device, MATRIX_BYTES, krnl.group_id(2));

    memcpy(bo_w.map<float*>(),   W, MATRIX_BYTES);
    memcpy(bo_x.map<float*>(),   X, MATRIX_BYTES);
    memset(bo_out.map<float*>(), 0, MATRIX_BYTES);

    bo_w.sync(XCL_BO_SYNC_BO_TO_DEVICE);
    bo_x.sync(XCL_BO_SYNC_BO_TO_DEVICE);
    bo_out.sync(XCL_BO_SYNC_BO_TO_DEVICE);

    auto t_start = std::chrono::high_resolution_clock::now();
    auto run = krnl(bo_w, bo_x, bo_out);
    run.wait();
    auto t_end = std::chrono::high_resolution_clock::now();
    double ms = std::chrono::duration<double, std::milli>(t_end - t_start).count();

    bo_out.sync(XCL_BO_SYNC_BO_FROM_DEVICE);

    float ref[TOTAL];
    compute_ref(W, X, ref);

    bool pass = matrices_close(bo_out.map<float*>(), ref);
    std::cout << "[" << label << "] " << (pass ? "PASS" : "FAIL")
              << "  (" << std::fixed << std::setprecision(2) << ms << " ms)\n";

    if (print_output) {
        print_matrix("  OUT", bo_out.map<float*>());
    }

    return pass;
}

static void print_help(const char* prog) {
    std::cout << "Usage: " << prog << " -x <xclbin> [-d <device_id>]\n";
}

int main(int argc, char* argv[]) {
    std::string xclbin;
    int dev_id = 0;

    for (int opt; (opt = getopt(argc, argv, "x:d:")) != -1;) {
        switch (opt) {
            case 'x': xclbin = optarg; break;
            case 'd': dev_id = std::stoi(optarg); break;
            default: print_help(argv[0]); return EXIT_FAILURE;
        }
    }
    if (xclbin.empty()) { print_help(argv[0]); return EXIT_FAILURE; }

    std::cout << "Opening device " << dev_id << "\n";
    auto device = xrt::device(dev_id);
    std::cout << "Loading " << xclbin << "\n";
    auto uuid = device.load_xclbin(xclbin);
    auto krnl = xrt::kernel(device, uuid, "krnl_matmul");

    bool all_pass = true;
    float W[TOTAL], X[TOTAL];

    std::cout << "\n=== Correctness tests ===\n";

    // Test 1: W = I  →  OUT = X
    {
        memset(W, 0, MATRIX_BYTES);
        for (int i = 0; i < N; i++) W[i*N+i] = 1.0f;
        for (int i = 0; i < TOTAL; i++) X[i] = float(i + 1);
        all_pass &= run_test(device, krnl, "Identity (W=I)", W, X);
    }

    // Test 2: W = 2*I  →  OUT = 2*X
    {
        memset(W, 0, MATRIX_BYTES);
        for (int i = 0; i < N; i++) W[i*N+i] = 2.0f;
        for (int i = 0; i < N; i++)
            for (int j = 0; j < N; j++)
                X[i*N+j] = float(i + 1);
        all_pass &= run_test(device, krnl, "Scale-2 (W=2I)", W, X);
    }

    // Test 3: W = 0  →  OUT = 0
    {
        memset(W, 0, MATRIX_BYTES);
        for (int i = 0; i < TOTAL; i++) X[i] = float(i + 1);
        all_pass &= run_test(device, krnl, "Zero-weight", W, X);
    }

    // Test 4: Small integer matrices
    {
        for (int i = 0; i < N; i++)
            for (int j = 0; j < N; j++) {
                W[i*N+j] = float((i + j + 1) % 4);
                X[i*N+j] = float((i * 2 + j + 1) % 4);
            }
        all_pass &= run_test(device, krnl, "Small integers", W, X);
    }

    // Test 5: Diagonal weight W = diag(1,2,...,N)
    {
        memset(W, 0, MATRIX_BYTES);
        for (int i = 0; i < N; i++) W[i*N+i] = float(i + 1);
        for (int i = 0; i < TOTAL; i++) X[i] = 1.0f;
        all_pass &= run_test(device, krnl, "Diagonal weight", W, X);
    }

    std::cout << "\n=== Random dense matrix tests (with output) ===\n";

    // Tests 6-8: Random dense matrices
    std::mt19937 rng;
    std::uniform_real_distribution<float> dist(-1.0f, 1.0f);

    const char* labels[] = {"Random-1 (seed=42)", "Random-2 (seed=123)", "Random-3 (seed=999)"};
    unsigned int seeds[]  = {42, 123, 999};

    for (int t = 0; t < 3; t++) {
        rng.seed(seeds[t]);
        for (int i = 0; i < TOTAL; i++) {
            W[i] = dist(rng);
            X[i] = dist(rng);
        }
        all_pass &= run_test(device, krnl, labels[t], W, X, /*print_output=*/true);
    }

    std::cout << "\n" << (all_pass ? "ALL TESTS PASSED" : "SOME TESTS FAILED") << "\n";
    return all_pass ? EXIT_SUCCESS : EXIT_FAILURE;
}
