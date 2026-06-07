//// =============================================================================
//// File Name     : s2b_sar.sv
//// Description   : Successive Approximation Register (SAR) Stochastic-to-Binary
////                 Converter. Instantiates its own internal SNG feedback loop
////                 to cleanly resolve external stochastic input streams.
//// =============================================================================

//`timescale 1ns/1ps

//module s2b_sar #(
//    parameter int WIDTH      = 8,   // Resolution of the output binary value
//    parameter int STREAM_LEN = 256  // Integration window size per bit decision
//) (
//    input  logic             clk,            // Global system clock
//    input  logic             rst_n,          // Synchronous active-low master reset
//    input  logic             start,          // Initiates the SAR binary search sequence
//    input  logic             stoch_target,   // External target input stochastic stream
//    input  logic [WIDTH-1:0] sng_seed,       // Randomization seed for internal feedback SNG
    
//    output logic [WIDTH-1:0] binary_out,     // Converged parallel deterministic result
//    output logic             valid           // Data valid strobe (asserted for 1 cycle when done)
//);

//    // Automatically derive internal counter bit-width from STREAM_LEN
//    localparam int CNT_W = $clog2(STREAM_LEN + 1);

//    // State Machine States
//    typedef enum logic [1:0] {
//        IDLE  = 2'b00,
//        TEST  = 2'b01,
//        WAIT  = 2'b10,
//        DONE  = 2'b11
//    } state_t;

//    state_t state;
//    logic [WIDTH-1:0] sar_reg;
//    logic [WIDTH-1:0] bit_mask;

//    // Counter Interfaces
//    logic             s2b_start;
//    logic             s2b_done_target;
//    logic             s2b_done_feedback;
//    logic [CNT_W-1:0] count_target;
//    logic [CNT_W-1:0] count_feedback;
    
//    // Internal Feedback Streams
//    logic             stoch_feedback; // No longer a port! Driven internally by SNG.
//    logic             sng_enable;

//    assign sng_enable = (state != IDLE);

//    // =========================================================================
//    // Missing Component: Internal Feedback Stochastic Number Generator (SNG)
//    // =========================================================================
//    // This SNG is driven directly by the SAR register guess to create the feedback stream
//    sar_internal_sng #(.WIDTH(WIDTH)) u_feedback_sng (
//        .clk      (clk),
//        .rst_n    (rst_n),
//        .enable   (sng_enable),
//        .binary_in(sar_reg),
//        .seed     (sng_seed),
//        .stoch_out(stoch_feedback) // Drives the wire directly, removing 'Z'
//    );

//    // =========================================================================
//    // Counter 1: Integrates the Target Input Stochastic Stream
//    // =========================================================================
//    s2b_counter #(
//        .STREAM_LEN(STREAM_LEN)
//    ) u_s2b_target (
//        .clk       (clk),
//        .rst_n     (rst_n),
//        .start     (s2b_start),
//        .stoch_in  (stoch_target),
//        .binary_out(count_target),
//        .done      (s2b_done_target)
//    );

//    // =========================================================================
//    // Counter 2: Integrates the Internal Feedback Stochastic Stream
//    // =========================================================================
//    s2b_counter #(
//        .STREAM_LEN(STREAM_LEN)
//    ) u_s2b_feedback (
//        .clk       (clk),
//        .rst_n     (rst_n),
//        .start     (s2b_start),
//        .stoch_in  (stoch_feedback),
//        .binary_out(count_feedback),
//        .done      (s2b_done_feedback)
//    );

//    // =========================================================================
//    // SAR Control Engine & Digital Comparator Loop
//    // =========================================================================
//    always_ff @(posedge clk) begin
//        if (!rst_n) begin
//            state      <= IDLE;
//            sar_reg    <= '0;
//            bit_mask   <= '0;
//            binary_out <= '0;
//            valid      <= 1'b0;
//        end else begin
//            valid <= 1'b0;

//            case (state)
//                IDLE: begin
//                    if (start) begin
//                        bit_mask <= (1'b1 << (WIDTH - 1));
//                        sar_reg  <= (1'b1 << (WIDTH - 1)); // Start guess at mid-scale (e.g., 128)
//                        state    <= TEST;
//                    end
//                end

//                TEST: begin
//                    state <= WAIT;
//                end

//                WAIT: begin
//                    if (s2b_done_target && s2b_done_feedback) begin
                        
//                        // Compare accumulated counts to see if the guess was too high or low
//                        logic [WIDTH-1:0] decision_sar;
//                        decision_sar = (count_target >= count_feedback) ? sar_reg : (sar_reg & ~bit_mask);

//                        // Check if we finished evaluating the LSB
//                        if (bit_mask == 1'b1) begin
//                            binary_out <= decision_sar;
//                            valid      <= 1'b1;
//                            state      <= DONE;
//                        end else begin
//                            // Advance to the next bit position to the right
//                            bit_mask <= bit_mask >> 1;
//                            sar_reg  <= decision_sar | (bit_mask >> 1); // Set next bit to '1' to test it
//                            state    <= TEST;
//                        end
//                    end
//                end

//                DONE: begin
//                    state <= IDLE;
//                end
                
//                default: state <= IDLE;
//            endcase
//        end
//    end

//    assign s2b_start = (state == TEST);

//endmodule


//// =============================================================================
//// Embedded Support Sub-Module: Linear Feedback Shift Register SNG
//// =============================================================================
//module sar_internal_sng #(
//    parameter int WIDTH = 8
//) (
//    input  logic             clk,
//    input  logic             rst_n,
//    input  logic             enable,
//    input  logic [WIDTH-1:0] binary_in,
//    input  logic [WIDTH-1:0] seed,
//    output logic             stoch_out
//);
//    logic [7:0] lfsr;

//    always_ff @(posedge clk) begin
//        if (!rst_n) begin
//            // Avoid getting stuck in an all-zero deadlock state
//            lfsr <= (seed == '0) ? 8'hA5 : seed; 
//        end else if (enable) begin
//            // Maximal-length 8-bit LFSR polynomial taps
//            lfsr <= {lfsr[6:0], lfsr[7] ^ lfsr[5] ^ lfsr[4] ^ lfsr[3]};
//        end
//    end

//    // Always driven combinational output—completely prevents High-Z (Z)
//    assign stoch_out = (binary_in > lfsr) ? 1'b1 : 1'b0;

//endmodule



// =============================================================================
// File Name     : s2b_sar.sv
// Description   : Successive Approximation Register (SAR) Stochastic-to-Binary
//                 Converter with Progressive Variable-Window Scaling.
//                 The integration window doubles at each consecutive bit step.
// =============================================================================

`timescale 1ns/1ps

module s2b_sar #(
    parameter int WIDTH      = 8,   // Resolution of the output binary value
    parameter int START_LEN  = 16*2*2*2*2*2*2,  // Integration window length used for the MSB
    parameter int MAX_LEN    = 128*2*2*2*2*2*2*2 // Maximum allowed window length bounds
) (
    input  logic             clk,            // Global system clock
    input  logic             rst_n,          // Synchronous active-low master reset
    input  logic             start,          // Initiates the SAR binary search sequence
    input  logic             stoch_target,   // External target input stochastic stream
    input  logic [WIDTH-1:0] sng_seed,       // Randomization seed for internal feedback SNG
    
    output logic [WIDTH-1:0] binary_out,     // Converged parallel deterministic result
    output logic             valid           // Data valid strobe (asserted for 1 cycle when done)
);

    // Derive counter bit widths based on the maximum allowed window size
    localparam int CNT_W = $clog2(MAX_LEN + 1);

    // State Machine States
    typedef enum logic [1:0] {
        IDLE  = 2'b00,
        TEST  = 2'b01,
        WAIT  = 2'b10,
        DONE  = 2'b11
    } state_t;

    state_t state;
    logic [WIDTH-1:0] sar_reg;
    logic [WIDTH-1:0] bit_mask;
    
    // Dynamic integration window tracking register
    logic [CNT_W-1:0] dynamic_window;

    // Counter Interfaces
    logic             s2b_start;
    logic             s2b_done_target;
    logic             s2b_done_feedback;
    logic [CNT_W-1:0] count_target;
    logic [CNT_W-1:0] count_feedback;
    
    // Internal Feedback Streams
    logic             stoch_feedback; 
    logic             sng_enable;

    assign sng_enable = (state != IDLE);

    // =========================================================================
    // Internal Feedback Stochastic Number Generator (SNG)
    // =========================================================================
    sar_internal_sng #(.WIDTH(WIDTH)) u_feedback_sng (
        .clk      (clk),
        .rst_n    (rst_n),
        .enable   (sng_enable),
        .binary_in(sar_reg),
        .seed     (sng_seed),
        .stoch_out(stoch_feedback)
    );

    // =========================================================================
    // Counter 1: Dynamic Input Target Integrator
    // =========================================================================
    s2b_dynamic_counter #(
        .MAX_LIMIT(MAX_LEN)
    ) u_s2b_target (
        .clk       (clk),
        .rst_n     (rst_n),
        .start     (s2b_start),
        .target_len(dynamic_window), // Driven by the runtime variable window length
        .stoch_in  (stoch_target),
        .binary_out(count_target),
        .done      (s2b_done_target)
    );

    // =========================================================================
    // Counter 2: Dynamic Feedback Integrator
    // =========================================================================
    s2b_dynamic_counter #(
        .MAX_LIMIT(MAX_LEN)
    ) u_s2b_feedback (
        .clk       (clk),
        .rst_n     (rst_n),
        .start     (s2b_start),
        .target_len(dynamic_window), // Driven by the runtime variable window length
        .stoch_in  (stoch_feedback),
        .binary_out(count_feedback),
        .done      (s2b_done_feedback)
    );

    // =========================================================================
    // SAR Control Engine with Variable Length Progression
    // =========================================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state          <= IDLE;
            sar_reg        <= '0;
            bit_mask       <= '0;
            dynamic_window <= '0;
            binary_out     <= '0;
            valid          <= 1'b0;
        end else begin
            valid <= 1'b0;

            case (state)
                IDLE: begin
                    if (start) begin
                        bit_mask       <= (1'b1 << (WIDTH - 1));
                        sar_reg        <= (1'b1 << (WIDTH - 1)); 
                        dynamic_window <= START_LEN[CNT_W-1:0]; // Initialize with baseline short window
                        state          <= TEST;
                    end
                end

                TEST: begin
                    state <= WAIT;
                end

                WAIT: begin
                    if (s2b_done_target && s2b_done_feedback) begin
                        
                        // Compare accumulated densities
                        logic [WIDTH-1:0] decision_sar;
                        decision_sar = (count_target >= count_feedback) ? sar_reg : (sar_reg & ~bit_mask);

                        // Check if we finished evaluating the LSB
                        if (bit_mask == 1'b1) begin
                            binary_out <= decision_sar;
                            valid      <= 1'b1;
                            state      <= DONE;
                        end else begin
                            // 1. Advance the pointer to the next bit down
                            bit_mask <= bit_mask >> 1;
                            sar_reg  <= decision_sar | (bit_mask >> 1);
                            
                            // 2. PROGRESSIVE STEP: Double the integration window for the next bit down
                            // Safeguard prevents shifting past max bounds parameter limit
                            if (dynamic_window < MAX_LEN[CNT_W-1:0]) begin
                                dynamic_window <= dynamic_window << 1; 
                            end
                            
                            state    <= TEST;
                        end
                    end
                end

                DONE: begin
                    state <= IDLE;
                end
                
                default: state <= IDLE;
            endcase
        end
    end

    assign s2b_start = (state == TEST);

endmodule


// =============================================================================
// Helper Module: Dynamic S2B Bit Counter
// =============================================================================
module s2b_dynamic_counter #(
    parameter int MAX_LIMIT = 4096
) (
    input  logic                       clk,
    input  logic                       rst_n,
    input  logic                       start,
    input  logic [$clog2(MAX_LIMIT+1)-1:0] target_len, // Runtime dynamic bound config
    input  logic                       stoch_in,
    output logic [$clog2(MAX_LIMIT+1)-1:0] binary_out,
    output logic                       done
);

    localparam int CNT_W = $clog2(MAX_LIMIT + 1);
    
    logic [CNT_W-1:0] count;
    logic [CNT_W-1:0] cycles;
    logic             busy;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            count      <= '0;
            cycles     <= '0;
            busy       <= 1'b0;
            done       <= 1'b0;
            binary_out <= '0;
        end else begin
            done <= 1'b0;
            
            if (start && !busy) begin
                count  <= '0;
                cycles <= '0;
                busy   <= 1'b1;
            end else if (busy) begin
                count  <= count + {{(CNT_W-1){1'b0}}, stoch_in};
                cycles <= cycles + 1'b1;
                
                // Compare cycles directly against the dynamic target_len signal value
                if (cycles == (target_len - 1'b1)) begin
                    binary_out <= count + {{(CNT_W-1){1'b0}}, stoch_in}; 
                    done       <= 1'b1;
                    busy       <= 1'b0;
                end
            end
        end
    end
endmodule


// =============================================================================
// Helper Module: Linear Feedback Shift Register SNG
// =============================================================================
module sar_internal_sng #(
    parameter int WIDTH = 8
) (
    input  logic             clk,
    input  logic             rst_n,
    input  logic             enable,
    input  logic [WIDTH-1:0] binary_in,
    input  logic [WIDTH-1:0] seed,
    output logic             stoch_out
);
    logic [7:0] lfsr;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            lfsr <= (seed == '0) ? 8'hA5 : seed; 
        end else if (enable) begin
            lfsr <= {lfsr[6:0], lfsr[7] ^ lfsr[5] ^ lfsr[4] ^ lfsr[3]};
        end
    end

    assign stoch_out = (binary_in > lfsr) ? 1'b1 : 1'b0;

endmodule
