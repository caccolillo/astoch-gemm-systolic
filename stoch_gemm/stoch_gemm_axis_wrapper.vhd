-- =============================================================================
-- stoch_gemm_axis_wrapper.vhd
-- VHDL entity/architecture wrapper around the SystemVerilog module
-- stoch_gemm_axis. Vivado's IP Integrator (block design) accepts VHDL
-- components directly without needing the IP Packager flow, sidestepping
-- the "SystemVerilog not allowed as top file in reference" error.
--
-- How Vivado resolves this
--   The VHDL entity is what the block design instantiates. During synthesis
--   Vivado links the VHDL entity to the SystemVerilog implementation of
--   stoch_gemm_axis (which is already in the project sources) via the
--   component name. No IP packaging, no -type module call, no component.xml.
--
-- Using in create_bd.tcl
--   Replace the create_bd_cell -type module line with:
--     set gemm [create_bd_cell -type module \
--               -reference stoch_gemm_axis_wrapper stoch_gemm_axis_0]
--   Then wire up ports exactly as before -- port names are identical.
--
-- Parameters (generics) match the SV defaults and can be overridden in the
-- block design GUI or via set_property CONFIG.* if you package this as IP.
--
-- Port names and directions are an EXACT copy of stoch_gemm_axis.sv to
-- guarantee correct port mapping during synthesis.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity stoch_gemm_axis_wrapper is
    generic (
        N                   : integer := 8;
        WIDTH               : integer := 16;
        LFSR_W              : integer := 16;
        STREAM_LEN          : integer := 1024;
        KW                  : integer := 16;
        KBUF_MAX            : integer := 64;
        C_S_AXI_ADDR_WIDTH  : integer := 12;
        C_S_AXI_DATA_WIDTH  : integer := 32
    );
    port (
        -- Clock / reset
        aclk            : in  std_logic;
        aresetn         : in  std_logic;    -- active-LOW

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

        -- Interrupt to PS
        irq             : out std_logic
    );
end entity stoch_gemm_axis_wrapper;

architecture structural of stoch_gemm_axis_wrapper is

    -- -------------------------------------------------------------------------
    -- Component declaration mirrors the SystemVerilog module.
    -- Vivado's synthesis links this declaration to the SV source at elaboration.
    -- -------------------------------------------------------------------------
    component stoch_gemm_axis
        generic (
            N                   : integer := 8;
            WIDTH               : integer := 16;
            LFSR_W              : integer := 16;
            STREAM_LEN          : integer := 1024;
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
            s_axis_tvalid   : in  std_logic;
            s_axis_tready   : out std_logic;
            s_axis_tlast    : in  std_logic;
            m_axis_tdata    : out std_logic_vector(31 downto 0);
            m_axis_tvalid   : out std_logic;
            m_axis_tready   : in  std_logic;
            m_axis_tlast    : out std_logic;
            irq             : out std_logic
        );
    end component stoch_gemm_axis;

begin

    -- -------------------------------------------------------------------------
    -- Instantiate the SystemVerilog core, passing all generics through.
    -- -------------------------------------------------------------------------
    u_core : stoch_gemm_axis
        generic map (
            N                   => N,
            WIDTH               => WIDTH,
            LFSR_W              => LFSR_W,
            STREAM_LEN          => STREAM_LEN,
            KW                  => KW,
            KBUF_MAX            => KBUF_MAX,
            C_S_AXI_ADDR_WIDTH  => C_S_AXI_ADDR_WIDTH,
            C_S_AXI_DATA_WIDTH  => C_S_AXI_DATA_WIDTH
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
            s_axis_tvalid   => s_axis_tvalid,
            s_axis_tready   => s_axis_tready,
            s_axis_tlast    => s_axis_tlast,
            m_axis_tdata    => m_axis_tdata,
            m_axis_tvalid   => m_axis_tvalid,
            m_axis_tready   => m_axis_tready,
            m_axis_tlast    => m_axis_tlast,
            irq             => irq
        );

end architecture structural;
