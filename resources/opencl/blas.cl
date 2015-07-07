#ifndef REAL
    #define REAL float
#endif

#ifndef WGS
    #define WGS 256
#endif

#ifndef WGSm
    #define WGSm 16
#endif

#ifndef WGSn
#define WGSn 16
#endif

//|||||||||||||||||       BLAS 1       |||||||||||||||||||||||||||||||||||||||||

// ================ Embarassingly parallel kernels =============================

__attribute__((reqd_work_group_size(WGS, 1, 1)))
__kernel void swp (__global REAL* x, __global REAL* y) {
    uint gid = get_global_id(0);
    REAL temp = x[gid];
    x[gid] = y[gid];
    y[gid] = temp;
}

__attribute__((reqd_work_group_size(WGS, 1, 1)))
__kernel void scal (__private const REAL alpha, __global REAL* x) {
    uint gid = get_global_id(0);
    x[gid] = alpha * x[gid];
}

__attribute__((reqd_work_group_size(WGS, 1, 1)))
__kernel void axpy (__private const REAL alpha, __global const REAL* x,
                     __global REAL* y) {
    uint gid = get_global_id(0);
    y[gid] = alpha * x[gid] + y[gid];
}

__attribute__((reqd_work_group_size(WGS, 1, 1)))
__kernel void xpby (__global const double* x,
                    const REAL beta, __global REAL* y) {
    uint gid = get_global_id(0);
    y[gid] = x[gid] + beta * y[gid];
}

// ================= Sum reduction =============================================

inline void work_group_reduction_sum (__global double* acc, const double value) {

    uint local_size = get_local_size(0);
    uint local_id = get_local_id(0);

    __local double lacc[WGS];
    lacc[local_id] = value;

    work_group_barrier(CLK_LOCAL_MEM_FENCE);

    double pacc = value;
    uint i = local_size;
    while (i > 0) {
        bool include_odd = (i > ((i >> 1) << 1)) && (local_id == ((i >> 1) - 1));
        i >>= 1;
        if (include_odd) {
            pacc += lacc[local_id + i + 1];
        }
        if (local_id < i) {
            pacc += lacc[local_id + i];
            lacc[local_id] = pacc;
        }
        work_group_barrier(CLK_LOCAL_MEM_FENCE);
    }

    if(local_id == 0) {
        acc[get_group_id(0)] = pacc;
    }
}

__attribute__((reqd_work_group_size(WGS, 1, 1)))
__kernel void sum_reduction (__global double* acc) {
    work_group_reduction_sum(acc, acc[get_global_id(0)]);
}

// ================== Dot product ==============================================
__attribute__((reqd_work_group_size(WGS, 1, 1)))
__kernel void dot_reduce (__global double* acc,
                          __global const REAL* x, __global const REAL* y) {
    uint gid = get_global_id(0);
    work_group_reduction_sum(acc, (double)(x[gid] * y[gid]));
}

// ================== asum =====================================================
__attribute__((reqd_work_group_size(WGS, 1, 1)))
__kernel void asum_reduce (__global double* acc, __global const REAL* x) {
    work_group_reduction_sum(acc, (double)fabs(x[get_global_id(0)]));
}

// ================== nrm2 =====================================================

__attribute__((reqd_work_group_size(WGS, 1, 1)))
__kernel void nrm2_reduce (__global double* acc, __global const REAL* x) {
    work_group_reduction_sum(acc, (double)pown(x[get_global_id(0)], 2));
}

// ================ Max reduction ==============================================
__attribute__((reqd_work_group_size(WGS, 1, 1)))
inline void work_group_reduction_imax (__global uint* iacc,
                                       __global double* vacc,
                                       uint const ind, const double val) {

    uint local_id = get_local_id(0);
    uint local_size = get_local_size(0);

    __local uint liacc[WGS];
    __local double lvacc[WGS];
    liacc[local_id] = ind;
    lvacc[local_id] = val;

    work_group_barrier(CLK_LOCAL_MEM_FENCE);

    uint index = ind;
    double value = val;

    uint i = local_size;
    while (i > 0) {
        bool include_odd = (i > ((i >> 1) << 1)) && (local_id == ((i >> 1) - 1));
        i >>= 1;
        if (include_odd) {
            double other_value = lvacc[local_id + i + 1];
            if (other_value > value) {
                value = other_value;
                index = liacc[local_id + i + 1];
                lvacc[local_id] = value;
                liacc[local_id] = index;
            }
        }
        if (local_id < i) {
            double other_value = lvacc[local_id + i];
            if (other_value > value) {
                value = other_value;
                index = liacc[local_id + i];
                lvacc[local_id] = value;
                liacc[local_id] = index;
            }
        }
        work_group_barrier(CLK_LOCAL_MEM_FENCE);
    }

    if(local_id == 0) {
        uint group_id = get_group_id(0);
        iacc[group_id] = index;
        vacc[group_id] = value;
    }

}

__attribute__((reqd_work_group_size(WGS, 1, 1)))
__kernel void imax_reduction (__global uint* iacc, __global double* vacc) {
    uint gid = get_global_id(0);
    work_group_reduction_imax(iacc, vacc, iacc[gid], (double)(vacc[gid]));
}

// ================== iamax reduce  ============================================

__attribute__((reqd_work_group_size(WGS, 1, 1)))
__kernel void iamax_reduce (__global uint* iacc, __global double* vacc,
                            __global const REAL* x) {
    uint gid = get_global_id(0);
    work_group_reduction_imax(iacc, vacc, gid, (double)(fabs(x[gid])));
}

// ||||||||||||||||       BLAS 2      ||||||||||||||||||||||||||||||||||||||||||

// ================== GEMV =====================================================

inline void work_group_reduction_sum_horizontal
(__global double* acc, const double value) {

    uint global_size_m = get_global_size(0);
    uint group_id_m = get_group_id(0);
    uint group_id_n = get_group_id(1);

    uint local_m = get_local_size(0);
    uint local_n = get_local_size(1);
    uint local_row = get_local_id(0);
    uint local_col = get_local_id(1);

    __local double lacc[WGSm][WGSn];
    lacc[local_row][local_col] = value;

    work_group_barrier(CLK_LOCAL_MEM_FENCE);

    double pacc = value;
    uint i = local_n;
    while (i > 0) {
        bool include_odd = (i > ((i >> 1) << 1)) && (local_col == ((i >> 1) - 1));
        i >>= 1;
        if (include_odd) {
            pacc += lacc[local_row][local_col + i + 1];
        }
        if (local_col < i) {
            pacc += lacc[local_row][local_col + i];
            lacc[local_row][local_col] = pacc;
        }
        work_group_barrier(CLK_LOCAL_MEM_FENCE);
    }

    if(local_col == 0) {
        acc[(global_size_m * group_id_n)
            + (group_id_m  * WGSm)
            + (global_size_m * local_col) + local_row] = pacc;
        //acc[get_global_id(0) * get_group_id(1) +
        //  WGSm * get_group_id(0) + local_row] = pacc;
    }
}

/* TODO: first make it work with only one pass (m x 16) and then do the final reduction
   Also think about doing some loops (or dot(float16)) in the kernel
   Maybe it'll be a good idea to concentrate on row-orientedness or, probably not because
   column-orientednes reads vector only once....*/
__attribute__((reqd_work_group_size(WGSm, WGSn, 1)))
__kernel void sum_reduction_horizontal (__global double* acc) {

    uint global_size_m = get_global_size(0);
    uint group_id_m = get_group_id(0);
    uint group_id_n = get_group_id(1);
    uint local_row = get_local_id(0);
    uint local_col = get_local_id(1);

    uint a_id = (global_size_m * WGSn * group_id_n)
        + (group_id_m  * WGSm)
        + (global_size_m * local_col) + local_row;

    work_group_reduction_sum_horizontal(acc, acc[a_id]);
}

// ================== Dot product ==============================================
__attribute__((reqd_work_group_size(WGSm, WGSn, 1)))
__kernel void gemv_reduce (__global double* acc,
                           const REAL alpha, __global const REAL* a,
                           __global const REAL* x) {

    uint global_size_m = get_global_size(0);
    uint group_id_m = get_group_id(0);
    uint group_id_n = get_group_id(1);
    uint local_row = get_local_id(0);
    uint local_col = get_local_id(1);

    uint a_id = (global_size_m * WGSn * group_id_n)
        + (group_id_m  * WGSm)
        + (global_size_m * local_col) + local_row;

    uint x_id = WGSn * group_id_n + local_col;

    work_group_reduction_sum_horizontal(acc, alpha * a[a_id] * x[x_id]);
}
