// ============================================================================
// mxu.sv — Parameterized Matrix Unit (systolic array wrapper)
//
// Generalization of minitpu's 4×4 mxu.sv to arbitrary N using for-loops
// in the FSM instead of hardcoded if-blocks.
//
// Computes: OUT = X * W^T  (N×N matrix multiply)
//
// FSM: IDLE → LOAD_W_REQ/WAIT → LOAD_X_REQ/WAIT → RUN → CAPTURE →
//      STORE_REQ/WAIT → DONE
//
// Memory interface: simple address + data + read/write enable.
// Same interface as minitpu's mxu.sv for cocotb test compatibility.
// ============================================================================

`timescale 1ns/1ps

module mxu #(
    parameter int N             = 16,
    parameter int DATA_WIDTH    = 32,
    parameter int BANKING_FACTOR = 1,
    parameter int ADDRESS_WIDTH = 16,
    parameter int MEM_LATENCY   = 2
)(
    input  logic clk,
    input  logic rst_n,

    // Control
    input  logic start,
    output logic done,

    // Base addresses (latched on start)
    input  logic [ADDRESS_WIDTH-1:0] base_addr_w,
    input  logic [ADDRESS_WIDTH-1:0] base_addr_x,
    input  logic [ADDRESS_WIDTH-1:0] base_addr_out,

    // Memory interface
    output logic [ADDRESS_WIDTH-1:0]                mem_req_addr,
    output logic [BANKING_FACTOR*DATA_WIDTH-1:0]    mem_req_data,
    input  logic [BANKING_FACTOR*DATA_WIDTH-1:0]    mem_resp_data,
    output logic                                    mem_read_en,
    output logic                                    mem_write_en
);

    localparam int TOTAL_ELEMS   = N * N;
    localparam int LOAD_IDX_BITS = $clog2(TOTAL_ELEMS + 1);
    localparam int PHASE_BITS    = $clog2(4 * N);
    localparam int ROW_PTR_BITS  = $clog2(N + 1);

    // =========================================================================
    // Local buffers
    // =========================================================================
    logic [DATA_WIDTH-1:0] weight_matrix [0:TOTAL_ELEMS-1];
    logic [DATA_WIDTH-1:0] x_matrix      [0:TOTAL_ELEMS-1];
    logic [DATA_WIDTH-1:0] out_matrix    [0:TOTAL_ELEMS-1];

    // Latched base addresses
    logic [ADDRESS_WIDTH-1:0] base_addr_w_reg, base_addr_x_reg, base_addr_out_reg;

    // Load/store index
    logic [LOAD_IDX_BITS-1:0] load_idx;
    wire [ADDRESS_WIDTH-1:0] load_idx_addr =
        {{(ADDRESS_WIDTH - LOAD_IDX_BITS){1'b0}}, load_idx};

    // Memory latency timer
    logic [$clog2(MEM_LATENCY + 1)-1:0] mem_latency_timer;

    // =========================================================================
    // Systolic array signals (flat packed vectors)
    // =========================================================================
    logic [N*DATA_WIDTH-1:0] sys_data_in;
    logic [N-1:0]            sys_valid_in;
    logic [N*DATA_WIDTH-1:0] sys_weight_in;
    logic [N-1:0]            sys_accept_w;
    logic                    sys_switch_in;
    logic [N*DATA_WIDTH-1:0] sys_data_out;
    logic [N-1:0]            sys_valid_out;

    // =========================================================================
    // Systolic array instance
    // =========================================================================
    systolic_array #(
        .N         (N),
        .DATA_WIDTH(DATA_WIDTH)
    ) u_array (
        .clk       (clk),
        .rst_n     (rst_n),
        .data_in   (sys_data_in),
        .valid_in  (sys_valid_in),
        .weight_in (sys_weight_in),
        .accept_w  (sys_accept_w),
        .switch_in (sys_switch_in),
        .data_out  (sys_data_out),
        .valid_out (sys_valid_out)
    );

    // =========================================================================
    // FSM
    // =========================================================================
    typedef enum logic [3:0] {
        S_IDLE,
        S_LOAD_W_REQ,
        S_LOAD_W_WAIT,
        S_LOAD_X_REQ,
        S_LOAD_X_WAIT,
        S_RUN,
        S_CAPTURE,
        S_STORE_REQ,
        S_STORE_WAIT,
        S_DONE
    } state_t;

    state_t state;
    logic [PHASE_BITS-1:0] phase_counter;
    logic [ROW_PTR_BITS-1:0] row_ptr [0:N-1];

    // =========================================================================
    // Output capture — separate always block
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < N; i++)
                row_ptr[i] <= '0;
            for (int i = 0; i < TOTAL_ELEMS; i++)
                out_matrix[i] <= '0;
        end else begin
            if (start) begin
                for (int i = 0; i < N; i++)
                    row_ptr[i] <= '0;
                for (int i = 0; i < TOTAL_ELEMS; i++)
                    out_matrix[i] <= '0;
            end else begin
                for (int col = 0; col < N; col++) begin
                    if (sys_valid_out[col] && row_ptr[col] < N[ROW_PTR_BITS-1:0]) begin
                        out_matrix[row_ptr[col] * N + col] <= sys_data_out[col*DATA_WIDTH +: DATA_WIDTH];
                        row_ptr[col] <= row_ptr[col] + 1;
                    end
                end
            end
        end
    end

    // =========================================================================
    // Main FSM
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= S_IDLE;
            phase_counter   <= '0;
            mem_req_addr    <= '0;
            mem_req_data    <= '0;
            mem_read_en     <= 0;
            mem_write_en    <= 0;
            mem_latency_timer <= '0;
            load_idx        <= '0;
            done            <= 0;
            base_addr_w_reg <= '0;
            base_addr_x_reg <= '0;
            base_addr_out_reg <= '0;

            for (int i = 0; i < TOTAL_ELEMS; i++) begin
                weight_matrix[i] <= '0;
                x_matrix[i]      <= '0;
            end

            sys_data_in   <= '0;
            sys_valid_in  <= '0;
            sys_weight_in <= '0;
            sys_accept_w  <= '0;
            sys_switch_in <= 0;
        end else begin
            // Defaults
            done         <= 0;
            mem_req_addr <= '0;
            mem_req_data <= '0;
            mem_read_en  <= 0;
            mem_write_en <= 0;

            sys_data_in   <= '0;
            sys_valid_in  <= '0;
            sys_weight_in <= '0;
            sys_accept_w  <= '0;
            sys_switch_in <= 0;

            case (state)
                // =============================================================
                S_IDLE: begin
                    if (start) begin
                        base_addr_w_reg   <= base_addr_w;
                        base_addr_x_reg   <= base_addr_x;
                        base_addr_out_reg <= base_addr_out;
                        load_idx          <= '0;
                        state             <= S_LOAD_W_REQ;
                    end
                end

                // =============================================================
                // Load weight matrix from memory
                // =============================================================
                S_LOAD_W_REQ: begin
                    mem_req_addr      <= base_addr_w_reg + load_idx_addr;
                    mem_read_en       <= 1;
                    mem_latency_timer <= '0;
                    state             <= S_LOAD_W_WAIT;
                end

                S_LOAD_W_WAIT: begin
                    if (mem_latency_timer >= MEM_LATENCY[$bits(mem_latency_timer)-1:0] - 1) begin
                        for (int b = 0; b < BANKING_FACTOR; b++) begin
                            int flat_index;
                            flat_index = int'(load_idx) * BANKING_FACTOR + b;
                            if (flat_index < TOTAL_ELEMS)
                                weight_matrix[flat_index] <= mem_resp_data[b*DATA_WIDTH +: DATA_WIDTH];
                        end
                        if ((int'(load_idx) + 1) * BANKING_FACTOR >= TOTAL_ELEMS) begin
                            load_idx <= '0;
                            state    <= S_LOAD_X_REQ;
                        end else begin
                            load_idx <= load_idx + 1;
                            state    <= S_LOAD_W_REQ;
                        end
                    end else begin
                        mem_latency_timer <= mem_latency_timer + 1;
                    end
                end

                // =============================================================
                // Load X matrix from memory
                // =============================================================
                S_LOAD_X_REQ: begin
                    mem_req_addr      <= base_addr_x_reg + load_idx_addr;
                    mem_read_en       <= 1;
                    mem_latency_timer <= '0;
                    state             <= S_LOAD_X_WAIT;
                end

                S_LOAD_X_WAIT: begin
                    if (mem_latency_timer >= MEM_LATENCY[$bits(mem_latency_timer)-1:0] - 1) begin
                        for (int b = 0; b < BANKING_FACTOR; b++) begin
                            int flat_index;
                            flat_index = int'(load_idx) * BANKING_FACTOR + b;
                            if (flat_index < TOTAL_ELEMS)
                                x_matrix[flat_index] <= mem_resp_data[b*DATA_WIDTH +: DATA_WIDTH];
                        end
                        if ((int'(load_idx) + 1) * BANKING_FACTOR >= TOTAL_ELEMS) begin
                            load_idx      <= '0;
                            phase_counter <= '0;
                            state         <= S_RUN;
                        end else begin
                            load_idx <= load_idx + 1;
                            state    <= S_LOAD_X_REQ;
                        end
                    end else begin
                        mem_latency_timer <= mem_latency_timer + 1;
                    end
                end

                // =============================================================
                // RUN: drive weights, switch, and X inputs into systolic array
                //
                // Weight pipeline: column c loads at phases [c, c+N-1]
                //   weight value = weight_matrix[c*N + N-1-(phase-c)]
                //   (reversed row order so bottom PE gets first weight)
                //
                // Switch: fires at phase N-1 (last weight of column 0)
                //
                // X input: row r feeds at phases [N+r, N+r+N-1]
                //   x value = x_matrix[(phase-N-r)*N + r]
                //
                // End: phase >= 3*N - 2
                // =============================================================
                S_RUN: begin
                    phase_counter <= phase_counter + 1;

                    // Weight pipeline
                    for (int col = 0; col < N; col++) begin
                        if (int'(phase_counter) >= col && int'(phase_counter) < col + N) begin
                            int p;
                            p = int'(phase_counter) - col;
                            sys_weight_in[col*DATA_WIDTH +: DATA_WIDTH] <= weight_matrix[col*N + N-1-p];
                            sys_accept_w[col] <= 1;
                        end
                    end

                    // Switch at phase N-1
                    if (phase_counter == N[PHASE_BITS-1:0] - 1)
                        sys_switch_in <= 1;

                    // X input pipeline
                    for (int row = 0; row < N; row++) begin
                        int ph;
                        ph = int'(phase_counter) - (N + row);
                        if (ph >= 0 && ph < N) begin
                            sys_data_in[row*DATA_WIDTH +: DATA_WIDTH] <= x_matrix[ph*N + row];
                            sys_valid_in[row] <= 1;
                        end
                    end

                    // End condition
                    if (phase_counter >= 3 * N[PHASE_BITS-1:0] - 2) begin
                        phase_counter <= '0;
                        state         <= S_CAPTURE;
                    end
                end

                // =============================================================
                // CAPTURE: wait for all outputs to propagate through array
                // =============================================================
                S_CAPTURE: begin
                    phase_counter <= phase_counter + 1;

                    begin
                        bit all_done;
                        all_done = 1;
                        for (int i = 0; i < N; i++)
                            all_done &= (row_ptr[i] >= N[ROW_PTR_BITS-1:0]);

                        // Watchdog: 4*N cycles should be more than enough
                        if (all_done || int'(phase_counter) >= 4 * N) begin
                            phase_counter <= '0;
                            load_idx      <= '0;
                            state         <= S_STORE_REQ;
                        end
                    end
                end

                // =============================================================
                // Store output matrix to memory
                // =============================================================
                S_STORE_REQ: begin
                    mem_req_addr <= base_addr_out_reg + load_idx_addr;

                    for (int b = 0; b < BANKING_FACTOR; b++) begin
                        int flat_index;
                        flat_index = int'(load_idx) * BANKING_FACTOR + b;
                        if (flat_index < TOTAL_ELEMS)
                            mem_req_data[b*DATA_WIDTH +: DATA_WIDTH] <= out_matrix[flat_index];
                        else
                            mem_req_data[b*DATA_WIDTH +: DATA_WIDTH] <= '0;
                    end

                    mem_write_en      <= 1;
                    mem_latency_timer <= '0;
                    state             <= S_STORE_WAIT;
                end

                S_STORE_WAIT: begin
                    if (mem_latency_timer >= MEM_LATENCY[$bits(mem_latency_timer)-1:0] - 1) begin
                        if ((int'(load_idx) + 1) * BANKING_FACTOR >= TOTAL_ELEMS) begin
                            state <= S_DONE;
                        end else begin
                            load_idx <= load_idx + 1;
                            state    <= S_STORE_REQ;
                        end
                    end else begin
                        mem_latency_timer <= mem_latency_timer + 1;
                    end
                end

                // =============================================================
                S_DONE: begin
                    done     <= 1;
                    load_idx <= '0;
                    state    <= S_IDLE;
                end

                default: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end

    // =========================================================================
    // Debug: break out out_matrix for waveform / cocotb access
    // =========================================================================
    generate
        for (genvar i = 0; i < TOTAL_ELEMS; i++) begin : OUT_DEBUG
            logic [DATA_WIDTH-1:0] out_elem;
            assign out_elem = out_matrix[i];
        end
    endgenerate

endmodule
