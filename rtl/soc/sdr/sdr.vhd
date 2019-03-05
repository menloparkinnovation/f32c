
--
-- 03/03/2019
--
-- Menlopark Innovation LLC.
--
-- Started from FM SoC to create general purpose SDR transmitter
-- for experienced ham radio experimenters.
--

--
-- Copyright (c) Davor Jadrijevic
-- All rights reserved.
--
-- Redistribution and use in source and binary forms, with or without
-- modification, are permitted provided that the following conditions
-- are met:
-- 1. Redistributions of source code must retain the above copyright
--    notice, this list of conditions and the following disclaimer.
-- 2. Redistributions in binary form must reproduce the above copyright
--    notice, this list of conditions and the following disclaimer in the
--    documentation and/or other materials provided with the distribution.
--
-- THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
-- ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
-- IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
-- ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
-- FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
-- DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
-- OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
-- HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
-- LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
-- OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
-- SUCH DAMAGE.
--
-- $Id$
--

-- CPU bus interface which glues together
-- fmrds, fmgen, bram_rds

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;
use ieee.std_logic_arith.all;
use ieee.numeric_std.all; -- we need signed type from here
use ieee.math_real.all; -- to calculate log2 bit size

entity sdr is
    generic (
        C_stereo: boolean := false;
        C_filter: boolean := false;
        C_downsample: boolean := false; -- LO-FI LUT-saving option as default
        C_rds_msg_len: integer range 2 to 2048 := 273; -- allocates RAM for RDS binary message
        -- some useful values for C_rds_msg_len
        --  13 =        1*13 (CT)
        --  52 =        4*13 (PS)
        -- 260 =   (16+4)*13 (PS+RT)
        -- 273 = (16+4+1)*13 (PS+RT+CT)
        -- PS:  4 groups, main display 8 characters
        -- RT: 16 groups, long display 64 characters
        -- CT:  1 group,  time information
        -- 1 group is 13 bytes long
        C_readable_reg: boolean := false; -- make registers readable (can work without, LUT saving)
        C_fmdds_hz: integer;           -- Hz clk_fmdds (>2*108 MHz, e.g. 250 MHz, 325 MHz)
        C_rds_clock_multiply: integer; -- multiply and divide from cpu clk 81.25 MHz
        C_rds_clock_divide: integer    -- to get 1.824 MHz for RDS logic
    );
    port (
	ce, clk: in std_logic;
	bus_write: in std_logic;
	addr: in std_logic_vector(5 downto 0); -- Decodes 256 bytes or 64 32 bit registers
	byte_sel: in std_logic_vector(3 downto 0);
	bus_in: in std_logic_vector(31 downto 0);
	bus_out: out std_logic_vector(31 downto 0);
	fm_irq: out std_logic; -- interrupt request line (active level high)
	clk_fmdds: in std_logic; -- DDS clock, must be > 2x max cw_freq, normally > 216 MHz
	pcm_in_left, pcm_in_right: in ieee.numeric_std.signed(15 downto 0) := (others => '0'); -- PCM audio input
	pwm_out_left, pwm_out_right: out std_logic;
	fm_antenna: out std_logic -- pyhsical output
    );
end sdr;

architecture arch of sdr is
    
    -- Menlo: Update to 8 32 bit registers
    constant C_registers: integer := 8; -- # of registers with memory <= (less or equal of) # of all registers
    -- constant C_registers: integer := 3; -- # of registers with memory <= (less or equal of) # of all registers

    constant C_bits: integer := 32;     -- don't touch, default bit size of memory registers

    -- bits for RDS message buffer
    constant C_addr_bits: integer := integer(ceil((log2(real(C_rds_msg_len)+1.0E-6))-1.0E-6));

    -- message len -1 disables RDS
    constant C_rds_msg_disable: std_logic_vector(c_addr_bits-1 downto 0) := (others => '1');
    
    -- normal registers
    -- type fm_reg_type  is std_logic_vector(C_bits-1 downto 0);
    type fm_regs_type is array (C_registers-1 downto 0) of std_logic_vector(C_bits-1 downto 0);
    signal R: fm_regs_type; -- register access from mmapped I/O  R: active register, Rtmp temporary

    -- *** REGISTERS ***
    -- named constants for fm registers
    -- this improves code readability
    -- and provides flexible register (re)numbering

    -- input from cpu: 32-bit set cw frequency
    constant C_cw_freq:    integer   := 0;

    -- input from cpu:  (7 downto 0)   8-bit RDS data sent in circular C_rds_msg_len
    --                  (15 downto 8)  Ignored
    --                  (31 downto 16) 16-bit RDS buffer addr to write data to
    constant C_rds_data:   integer   := 1;

    -- output to cpu: address currently being sent by RDS
    -- input from cpu: message length in (C_addr_bits-1 downto 0)
    constant C_rds_addr:   integer   := 2;

    constant C_rds_control: integer := 3;  -- Menlo: Added control register.

    -- SDR control registers
    constant C_sdr_control0: integer := 4;
    constant C_sdr_control1: integer := 5;
    constant C_sdr_control2: integer := 6;
    constant C_sdr_control3: integer := 7;

    -- FM/RDS RADIO
    signal rds_pcm_out: ieee.numeric_std.signed(15 downto 0); -- modulated PCM with audio and RDS
    signal rds_pcm_in: ieee.numeric_std.signed(15 downto 0);  -- modulated PCM with audio and RDS

    signal rds_addr: std_logic_vector(C_addr_bits-1 downto 0); -- RDS modulator reads BRAM from this addr during transmission
    signal rds_data: std_logic_vector(7 downto 0); -- BRAM returns value to RDS for transmission
    signal rds_bram_write: std_logic; -- decoded address -> write signal for BRAM
    signal R_rds_bram_write: std_logic := '0'; -- 1 clock delayed write signal to offload timing constraints
    signal from_fmrds: std_logic_vector(31 downto 0); -- debugging for subcarrier phase, not used
    signal rds_msg_len_in: std_logic_vector(c_addr_bits-1 downto 0);
    signal fm_antenna_out: std_logic;

    -- Menlo: Control signals
    signal rds_cw_en: std_logic;    -- carrier wave control
    signal rds_mod_en: std_logic;   -- modulator control
    signal rds_rds_data_en: std_logic;   -- RDS data control

begin

    --
    -- CPU core reads registers.
    --
    -- Register reads are always 32 bit.
    --
    -- N.B. select signal ce is not used in the decode since its expected
    -- the external caller has multiplexed the bus_out from this SoC entity.
    --
    readable_registers: if C_readable_reg generate -- LUT saving
    with conv_integer(addr) select
      bus_out <= 
        ext(rds_addr, 32)
          when C_rds_addr,
        ext(R(conv_integer(addr)), 32)
          when others;
    end generate;

    --
    -- CPU core writes registers.
    --
    -- The following decodes into individual byte selects
    -- for each register allowing individual register byte
    -- writes as the CPU core decodes A0 and A1 into byte_sel(3 - 0).
    --
    writereg_intrflags: for i in 0 to C_bits/8-1 generate
      process(clk)
      begin
        if rising_edge(clk) then
          if byte_sel(i) = '1' and ce = '1' and bus_write = '1' then
            R(conv_integer(addr))(8*i+7 downto 8*i) <=  bus_in(8*i+7 downto 8*i);
          end if;
        end if;
      end process;
    end generate;

    --
    -- FM RDS control register signals.
    --
    rds_cw_en <= R(C_rds_control)(0);
    rds_mod_en <= R(C_rds_control)(1);
    rds_rds_data_en <= R(C_rds_control)(2);

    -- Enable/Disable CW carrier
    fm_antenna <= fm_antenna_out
                 when rds_cw_en = '1'
                 else '0';

    -- Enable/Disable modulation
    rds_pcm_in <= rds_pcm_out
                   when rds_mod_en = '1'
                   else to_signed(0, 16);

    -- Enable/Disable RDS modulation
    rds_msg_len_in <= R(C_rds_addr)(C_addr_bits-1 downto 0)
                      when rds_rds_data_en = '1'
                      else C_rds_msg_disable;

    --
    -- SDR control register signals
    --

    --
    -- write to circular RDS memory when the low byte of
    -- register 1 is written.
    --
    rds_bram_write <= '1'
                 when byte_sel(0) = '1'
                  and ce = '1'
                  and bus_write = '1'
                  and conv_integer(addr) = C_rds_data
                 else '0';

    -- RAM write delay 1 clock cycle
    process(clk)
    begin
      if rising_edge(clk) then
        R_rds_bram_write <= rds_bram_write;
      end if;
    end process;

    --
    -- RDS takes PCM L + R audio in and a buffers with RDS messages
    -- and modulates them on pcm_out.
    --
    rds_modulator: entity work.rds
    generic map (
      c_addr_bits => C_addr_bits, -- number of address bits for RDS message RAM
      -- multiply/divide to produce 1.824 MHz clock
      c_rds_clock_multiply => C_rds_clock_multiply,
      c_rds_clock_divide => C_rds_clock_divide,
      -- example settings for 25 MHz clock
      -- c_rds_clock_multiply => 228,
      -- c_rds_clock_divide => 3125,
      -- settings for super slow (100Hz debug) clock
      -- c_rds_clock_multiply => 1,
      -- c_rds_clock_divide => 812500,
      c_filter => C_filter,
      c_downsample => C_downsample,
      c_stereo => C_stereo
    )
    port map (
      clk => clk, -- RDS and PCM processing clock, same as CPU clock

      rds_msg_len => rds_msg_len_in,

      addr => rds_addr, -- out, address driven by rds module
      data => rds_data,
      pcm_in_left => pcm_in_left,       -- PCM audio input
      pcm_in_right => pcm_in_right,     -- ""
      debug => from_fmrds,
      out_l => pwm_out_left,            -- Debug signals
      out_r => pwm_out_right,           -- ""
      pcm_out => rds_pcm_out            -- 16 bit PCM to FM transmitter
    );

    fm_modulator: entity work.fmgen
    generic map (
      c_fdds => real(C_fmdds_hz)
    )
    port map (
      clk_pcm => clk, -- PCM processing clock, same as CPU clock
      clk_dds => clk_fmdds, -- DDS clock must be > 2x cw_freq 
      cw_freq => R(C_cw_freq), -- Hz FM carrier wave frequency, e.g. 107900000
      pcm_in => rds_pcm_in,    -- 16 bit PCM modulation input
      fm_out => fm_antenna_out
    );

    rdsbram: entity work.bram_rds
    generic map (
	c_mem_bytes => C_rds_msg_len, -- allocate RAM for max message size
        c_addr_bits => C_addr_bits -- number of address bits for RDS message RAM
    )
    port map (
	clk => clk,
	imem_addr => rds_addr,     -- in, address input to bram_rds module
	imem_data_out => rds_data,
	dmem_write => R_rds_bram_write,
	dmem_addr => R(C_rds_data)(16+C_addr_bits-1 downto 16),
	dmem_data_out => open, dmem_data_in => R(C_rds_data)(7 downto 0)
    );

end;

--
-- registers:
-- 0: 32-bit CW frequency (write only)
-- 1: rds data (write only)
--    byte 0:    8-bit address data to write
--    byte 2-3: 11-bit address where to write
-- 2: byte 0-1: 11-bit address of current byte send (read)
--    byte 0-1: 11-bit RDS message length, address wraparound (write)

-- todo:
-- [ ] interrupt
-- [ ] reading from circular memory