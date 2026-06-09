-- =============================================================================
-- stoch_gemm_axis_wrapper_hybrid.vhd
-- VHDL wrapper around stoch_gemm_axis_hybrid (SystemVerilog).
-- Drop-in replacement for stoch_gemm_axis_wrapper.vhd in the block design:
-- same port list, same generic ordering, but the wrapped SV module is the
-- hybrid-converter version of the GEMM accelerator.
--
-- To use:
--   In bd.tcl, replace
--     create_bd_cell -type module -reference stoch_gemm_axis_wrapper
--   with
--     create_bd_cell -type module -reference stoch_gemm_axis_wrapper_hybrid
--   Same port wiring works because the entity port list is unchanged.
--
-- Generics added (hybrid-specific tuning knobs)
--   K_SAR_BITS          : how many top bits the SAR resolves (default 8)
--   SAR_BIT_LEN         : cycles per SAR bit, per term (default 32)
--   STREAM_LEN_RESIDUE  : residue counter length (default 65536)
--
-- The original STREAM_LEN generic is kept for source-compatibility with
-- bd.tcl but is ignored: the relevant length in hybrid mode is
-- STREAM_LEN_RESIDUE.
-- =============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity stoch_gemm_axis_wrapper_hybrid is
    generic (
        N                   : integer := 10;
        WIDTH               : integer := 16;
        LFSR_W              : integer := 16;
        STREAM_LEN          : integer := 8192;     -- ignored in hybrid mode
        K_SAR_BITS          : integer := 8;
        SAR_BIT_LEN         : integer := 32;
        STREAM_LEN_RESIDUE  : integer := 65536;
        KW                  : integer := 16;
        KBUF_MAX            : integer := 64;
        C_S_AXI_ADDR_WIDTH  : integer := 12;
        C_S_AXI_DATA_WIDTH  : integer := 32
    );
    port (
        -- Clock / reset
        aclk            : in  std_logic;
        aresetn         : in  std_logic;

        -- AXI4-Lite slave : control
        s_axi_awaddr    : in  std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);
        s_axi_awprot    : in  std_logic_vector(2 downto 0);
        s_axi_awvalid   : in  std_logic;
        s_axi_awready   : out std_logic;
        s_axi_wdata     : in  std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
        s_axi_wstrb     : in  std_logic_vector((C_S_AXI_DATA_WIDTH/8)-1 downto 0);
        s_axi_wvalid    : in  std_logic;
        s_axi_wready    : out std_logic;
        s_axi_bresp     : out std_logic_vector(1 downto 0);
        s_axi_bvalid    : out std_logic;
        s_axi_bready    : in  std_logic;
        s_axi_araddr    : in  std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);
        s_axi_arprot    : in  std_logic_vector(2 downto 0);
        s_axi_arvalid   : in  std_logic;
        s_axi_arready   : out std_logic;
        s_axi_rdata     : out std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
        s_axi_rresp     : out std_logic_vector(1 downto 0);
        s_axi_rvalid    : out std_logic;
        s_axi_rready    : in  std_logic;

        -- AXI4-Stream slave : operand input
        s_axis_tdata    : in  std_logic_vector(31 downto 0);
        s_axis_tvalid   : in  std_logic;
        s_axis_tready   : out std_logic;
        s_axis_tlast    : in  std_logic;

        -- AXI4-Stream master : result output
        m_axis_tdata    : out std_logic_vector(31 downto 0);
        m_axis_tvalid   : out std_logic;
        m_axis_tready   : in  std_logic;
        m_axis_tlast    : out std_logic;

        -- Interrupt
        irq             : out std_logic
    );
end entity stoch_gemm_axis_wrapper_hybrid;

architecture structural of stoch_gemm_axis_wrapper_hybrid is

    component stoch_gemm_axis_hybrid
        generic (
            N                   : integer := 8;
            WIDTH               : integer := 16;
            LFSR_W              : integer := 16;
            K_SAR_BITS          : integer := 8;
            SAR_BIT_LEN         : integer := 32;
            STREAM_LEN_RESIDUE  : integer := 65536;
            KW                  : integer := 16;
            KBUF_MAX            : integer := 64;
            C_S_AXI_ADDR_WIDTH  : integer := 12;
            C_S_AXI_DATA_WIDTH  : integer := 32
        );
        port (
            aclk            : in  std_logic;
            aresetn         : in  std_logic;
            s_axi_awaddr    : in  std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);
            s_axi_awprot    : in  std_logic_vector(2 downto 0);
            s_axi_awvalid   : in  std_logic;
            s_axi_awready   : out std_logic;
            s_axi_wdata     : in  std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
            s_axi_wstrb     : in  std_logic_vector((C_S_AXI_DATA_WIDTH/8)-1 downto 0);
            s_axi_wvalid    : in  std_logic;
            s_axi_wready    : out std_logic;
            s_axi_bresp     : out std_logic_vector(1 downto 0);
            s_axi_bvalid    : out std_logic;
            s_axi_bready    : in  std_logic;
            s_axi_araddr    : in  std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);
            s_axi_arprot    : in  std_logic_vector(2 downto 0);
            s_axi_arvalid   : in  std_logic;
            s_axi_arready   : out std_logic;
            s_axi_rdata     : out std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
            s_axi_rresp     : out std_logic_vector(1 downto 0);
            s_axi_rvalid    : out std_logic;
            s_axi_rready    : in  std_logic;
            s_axis_tdata    : in  std_logic_vector(31 downto 0);
            s_axis_tkeep    : in  std_logic_vector(3 downto 0);
            s_axis_tlast    : in  std_logic;
            s_axis_tvalid   : in  std_logic;
            s_axis_tready   : out std_logic;
            m_axis_tdata    : out std_logic_vector(31 downto 0);
            m_axis_tkeep    : out std_logic_vector(3 downto 0);
            m_axis_tlast    : out std_logic;
            m_axis_tvalid   : out std_logic;
            m_axis_tready   : in  std_logic;
            irq             : out std_logic
        );
    end component;

    signal s_axis_tkeep_int : std_logic_vector(3 downto 0);
    signal m_axis_tkeep_int : std_logic_vector(3 downto 0);

begin

    -- The block design AXI-Stream interface usually does not expose TKEEP;
    -- tie it high (all bytes valid) for the input side, ignore the output.
    s_axis_tkeep_int <= (others => '1');

    u_axis : stoch_gemm_axis_hybrid
        generic map (
            N                  => N,
            WIDTH              => WIDTH,
            LFSR_W             => LFSR_W,
            K_SAR_BITS         => K_SAR_BITS,
            SAR_BIT_LEN        => SAR_BIT_LEN,
            STREAM_LEN_RESIDUE => STREAM_LEN_RESIDUE,
            KW                 => KW,
            KBUF_MAX           => KBUF_MAX,
            C_S_AXI_ADDR_WIDTH => C_S_AXI_ADDR_WIDTH,
            C_S_AXI_DATA_WIDTH => C_S_AXI_DATA_WIDTH
        )
        port map (
            aclk            => aclk,
            aresetn         => aresetn,
            s_axi_awaddr    => s_axi_awaddr,
            s_axi_awprot    => s_axi_awprot,
            s_axi_awvalid   => s_axi_awvalid,
            s_axi_awready   => s_axi_awready,
            s_axi_wdata     => s_axi_wdata,
            s_axi_wstrb     => s_axi_wstrb,
            s_axi_wvalid    => s_axi_wvalid,
            s_axi_wready    => s_axi_wready,
            s_axi_bresp     => s_axi_bresp,
            s_axi_bvalid    => s_axi_bvalid,
            s_axi_bready    => s_axi_bready,
            s_axi_araddr    => s_axi_araddr,
            s_axi_arprot    => s_axi_arprot,
            s_axi_arvalid   => s_axi_arvalid,
            s_axi_arready   => s_axi_arready,
            s_axi_rdata     => s_axi_rdata,
            s_axi_rresp     => s_axi_rresp,
            s_axi_rvalid    => s_axi_rvalid,
            s_axi_rready    => s_axi_rready,
            s_axis_tdata    => s_axis_tdata,
            s_axis_tkeep    => s_axis_tkeep_int,
            s_axis_tlast    => s_axis_tlast,
            s_axis_tvalid   => s_axis_tvalid,
            s_axis_tready   => s_axis_tready,
            m_axis_tdata    => m_axis_tdata,
            m_axis_tkeep    => m_axis_tkeep_int,
            m_axis_tlast    => m_axis_tlast,
            m_axis_tvalid   => m_axis_tvalid,
            m_axis_tready   => m_axis_tready,
            irq             => irq
        );

end architecture structural;
