----------------------------------------------------------------------------------
-- Engineer: Mike Field <hamster@snap.net.nz>
-- 
-- Create Date:    14:09:12 09/15/2013 
-- Module Name:    SDRAM_Controller - Behavioral 
-- Description:    Simple SDRAM controller for a Micron 48LC16M16A2-7E
--                 or Micron 48LC4M16A2-7E @ 100MHz      
-- Revision: 
-- Revision 0.1 - Initial version
-- Revision 0.2 - Removed second clock signal that isn't needed.
-- Revision 0.3 - Added back-to-back reads and writes.
-- Revision 0.4 - Allow refeshes to be delayed till next PRECHARGE is issued,
--                Unless they get really, really delayed. If a delay occurs multiple
--                refreshes might get pushed out, but it will have avioded about 
--                50% of the refresh overhead
-- Revision 0.5 - Add more paramaters to the design, allowing it to work for both the 
--                Papilio Pro and Logi-Pi
-- Revision 0.6 - Fixed bugs in back-to-back reads (thanks Scotty!)
--
-- Worst case performance (single accesses to different rows or banks) is: 
-- Writes 16 cycles = 6,250,000 writes/sec = 25.0MB/s (excluding refresh overhead)
-- Reads  17 cycles = 5,882,352 reads/sec  = 23.5MB/s (excluding refresh overhead)
--
-- For 1:1 mixed reads and writes into the same row it is around 88MB/s 
-- For reads or writes to the same it can be as high as 184MB/s 
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
library UNISIM;
use UNISIM.VComponents.all;
use IEEE.NUMERIC_STD.ALL;


entity sdram_ctrl is
    generic (
      C_ras: integer range 2 to 3 := 2;
      C_cas: integer range 2 to 3 := 2;
      C_pre: integer range 2 to 3 := 2;
      C_clock_range: integer range 0 to 5 := 2; -- default:2
      C_ready_point: integer range 0 to 2 := 1; -- shift delay reg bit that represents data ready, default:1
      C_done_point: integer range 0 to 1 := 1; -- shift delay reg bit index when new transaction is accepted, default:1
      C_write_ready_delay: integer range 1 to 3 := 2; -- shift delay reg bit to set for write, default:2
      C_shift_read: boolean := false; -- if false use phase read (no shifting)
      C_allow_back_to_back: boolean := true;
      sdram_address_width : natural; -- ram size = 2^(sdram_address_width+1) bytes
      sdram_column_bits   : natural; -- from datasheet
      sdram_startup_cycles: natural;
      cycles_per_refresh  : natural
    );
    Port ( clk           : in  STD_LOGIC;
           reset         : in  STD_LOGIC;
           
           -- Interface to issue reads or write data
           cmd_ready         : out STD_LOGIC;                     -- '1' when a new command will be acted on
           cmd_enable        : in  STD_LOGIC;                     -- Set to '1' to issue new command (only acted on when cmd_read = '1')
           cmd_wr            : in  STD_LOGIC;                     -- Is this a write?
           cmd_address       : in  STD_LOGIC_VECTOR(sdram_address_width-2 downto 0); -- address to read/write
           cmd_byte_enable   : in  STD_LOGIC_VECTOR(3 downto 0);  -- byte masks for the write command
           cmd_data_in       : in  STD_LOGIC_VECTOR(31 downto 0); -- data for the write command
           
           data_out          : out STD_LOGIC_VECTOR(31 downto 0); -- word read from SDRAM
           data_out_ready    : out STD_LOGIC;                     -- is new data ready?
           ready_next_cycle  : out STD_LOGIC; -- ready signal 1 cycle ahead of time
           
           -- SDRAM signals
           SDRAM_CLK     : out   STD_LOGIC;
           SDRAM_CKE     : out   STD_LOGIC;
           SDRAM_CS      : out   STD_LOGIC;
           SDRAM_RAS     : out   STD_LOGIC;
           SDRAM_CAS     : out   STD_LOGIC;
           SDRAM_WE      : out   STD_LOGIC;
           sdram_dqm     : out   STD_LOGIC_VECTOR( 1 downto 0);
           SDRAM_ADDR    : out   STD_LOGIC_VECTOR(12 downto 0);
           SDRAM_BA      : out   STD_LOGIC_VECTOR( 1 downto 0);
           sdram_data    : inout STD_LOGIC_VECTOR(15 downto 0));
end sdram_ctrl;

architecture Behavioral of sdram_ctrl is
   -- From page 37 of MT48LC16M16A2 datasheet
   -- Name (Function)       CS# RAS# CAS# WE# DQM  Addr    Data
   -- COMMAND INHIBIT (NOP)  H   X    X    X   X     X       X
   -- NO OPERATION (NOP)     L   H    H    H   X     X       X
   -- ACTIVE                 L   L    H    H   X  Bank/row   X
   -- READ                   L   H    L    H  L/H Bank/col   X
   -- WRITE                  L   H    L    L  L/H Bank/col Valid
   -- BURST TERMINATE        L   H    H    L   X     X     Active
   -- PRECHARGE              L   L    H    L   X   Code      X
   -- AUTO REFRESH           L   L    L    H   X     X       X 
   -- LOAD MODE REGISTER     L   L    L    L   X  Op-code    X 
   -- Write enable           X   X    X    X   L     X     Active
   -- Write inhibit          X   X    X    X   H     X     High-Z

   -- Here are the commands mapped to constants   
   constant CMD_UNSELECTED    : std_logic_vector(3 downto 0) := "1000";
   constant CMD_NOP           : std_logic_vector(3 downto 0) := "0111";
   constant CMD_ACTIVE        : std_logic_vector(3 downto 0) := "0011";
   constant CMD_READ          : std_logic_vector(3 downto 0) := "0101";
   constant CMD_WRITE         : std_logic_vector(3 downto 0) := "0100";
   constant CMD_TERMINATE     : std_logic_vector(3 downto 0) := "0110";
   constant CMD_PRECHARGE     : std_logic_vector(3 downto 0) := "0010";
   constant CMD_REFRESH       : std_logic_vector(3 downto 0) := "0001";
   constant CMD_LOAD_MODE_REG : std_logic_vector(3 downto 0) := "0000";

   constant MODE_REG_CAS_2    : std_logic_vector(12 downto 0) := 
   -- Reserved, wr bust, OpMode, CAS Latency (2), Burst Type, Burst Length (2)
      "000" &   "0"  &  "00"  &    "010"      &     "0"    &   "001";
   constant MODE_REG_CAS_3    : std_logic_vector(12 downto 0) := 
   -- Reserved, wr bust, OpMode, CAS Latency (3), Burst Type, Burst Length (2)
      "000" &   "0"  &  "00"  &    "011"      &     "0"    &   "001";

   signal iob_command     : std_logic_vector( 3 downto 0) := CMD_NOP;
   signal iob_address     : std_logic_vector(12 downto 0) := (others => '0');
   signal iob_data        : std_logic_vector(15 downto 0) := (others => '0');
   signal iob_data_next   : std_logic_vector(15 downto 0) := (others => '0');
   signal iob_dqm         : std_logic_vector( 1 downto 0) := (others => '0');
   signal iob_cke         : std_logic := '0';
   signal iob_bank        : std_logic_vector( 1 downto 0) := (others => '0');
   
   attribute IOB: string;
   attribute IOB of iob_command: signal is "true";
   attribute IOB of iob_address: signal is "true";
   attribute IOB of iob_dqm    : signal is "true";
   attribute IOB of iob_cke    : signal is "true";
   attribute IOB of iob_bank   : signal is "true";
   attribute IOB of iob_data   : signal is "true";
   
   signal R_from_sdram: std_logic_vector(31 downto 0);
   
   type fsm_state is (s_startup,
                      s_idle_in_6, s_idle_in_5, s_idle_in_4,   s_idle_in_3, s_idle_in_2, s_idle_in_1,
                      s_idle,
                      s_open_in_2, s_open_in_1,
                      s_write_1, s_write_2, s_write_3,
                      s_read_1,  s_read_2,  s_read_3,  s_read_4,  
                      s_precharge
                      );

   signal state: fsm_state := s_startup;
   attribute FSM_ENCODING: string;
   attribute FSM_ENCODING of state : signal is "ONE-HOT";
   
   -- dual purpose counter, it counts up during the startup phase, then is used to trigger refreshes.
   constant startup_refresh_max   : unsigned(13 downto 0) := (others => '1');  
   signal   startup_refresh_count : unsigned(13 downto 0) := startup_refresh_max-to_unsigned(sdram_startup_cycles,14);

   -- logic to decide when to refresh
   signal pending_refresh : std_logic := '0';
   signal forcing_refresh : std_logic := '0';

   -- The incoming address is split into these three values
   signal addr_row         : std_logic_vector(12 downto 0) := (others => '0');
   signal addr_col         : std_logic_vector(12 downto 0) := (others => '0');
   signal addr_bank        : std_logic_vector( 1 downto 0) := (others => '0');
   
   signal dqm_sr           : std_logic_vector( 3 downto 0) := (others => '1'); -- an extra two bits in case CAS=3
   
   -- signals to hold the requested transaction before it is completed
   signal save_wr          : std_logic := '0';
   signal save_row         : std_logic_vector(12 downto 0);
   signal save_bank        : std_logic_vector( 1 downto 0);
   signal save_col         : std_logic_vector(12 downto 0);
   signal save_data_in     : std_logic_vector(31 downto 0);
   signal save_byte_enable : std_logic_vector( 3 downto 0);
   
   -- control when new transactions are accepted
   signal ready_for_new    : std_logic := '0';
   
   signal can_back_to_back : std_logic := '0';

   -- signal to control the Hi-Z state of the DQ bus
   signal iob_dq_hiz       : std_logic := '1';

   -- signals for when to read the data off of the bus
   signal data_ready_delay: std_logic_vector(C_clock_range/2+C_cas+1 downto 0);
   signal request_done: boolean;

   -- bit indexes used when splitting the address into row/colum/bank.
   constant start_of_col  : natural := 0;
   constant end_of_col    : natural := sdram_column_bits-2;
   constant start_of_bank : natural := sdram_column_bits-1;
   constant end_of_bank   : natural := sdram_column_bits;
   constant start_of_row  : natural := sdram_column_bits+1;
   constant end_of_row    : natural := sdram_address_width-2;
   constant prefresh_cmd  : natural := 10;
   
   signal S_let_back_to_back: boolean;

begin
   -- Indicate the need to refresh when the counter is 2048,
   -- Force a refresh when the counter is 4096 - (if a refresh is forced, 
   -- multiple refresshes will be forced until the counter is below 2048
   pending_refresh <= startup_refresh_count(11);
   forcing_refresh <= startup_refresh_count(12);

   -- tell the outside world when we can accept a new transaction;
   cmd_ready <= ready_for_new;
   ----------------------------------------------------------------------------
   -- Seperate the address into row / bank / address
   ----------------------------------------------------------------------------
   addr_row(end_of_row-start_of_row downto 0) <= cmd_address(end_of_row  downto start_of_row);       -- 12:0 <=  22:10
   addr_bank                                  <= cmd_address(end_of_bank downto start_of_bank);      -- 1:0  <=  9:8
   addr_col(sdram_column_bits-1 downto 0)     <= cmd_address(end_of_col  downto start_of_col) & '0'; -- 8:0  <=  7:0 & '0'

   -----------------------------------------------------------
   -- Forward the SDRAM clock to the SDRAM chip - 180 degress 
   -- out of phase with the control signals (ensuring setup and holdup
   -- as clock is inverted, then data must be sampled at falling
   -- edge and commands must be issued at rising edge of clk
   -----------------------------------------------------------
   sdram_clk <= not clk;

   -----------------------------------------------
   --!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
   --!! Ensure that all outputs are registered. !!
   --!! Check the pinout report to be sure      !!
   --!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
   -----------------------------------------------
   sdram_cke  <= iob_cke;
   sdram_CS   <= iob_command(3);
   sdram_RAS  <= iob_command(2);
   sdram_CAS  <= iob_command(1);
   sdram_WE   <= iob_command(0);
   sdram_dqm  <= iob_dqm;
   sdram_ba   <= iob_bank;
   sdram_addr <= iob_address;

   S_let_back_to_back <= C_allow_back_to_back
                     and forcing_refresh = '0'
                     and ready_for_new = '0'
                     and can_back_to_back = '1';
   ---------------------------------------------------------------
   -- Explicitly set up the tristate I/O buffers on the DQ signals
   ---------------------------------------------------------------
   sdram_data <= iob_data when iob_dq_hiz = '0' else (others => 'Z');

   shift_read: if C_shift_read generate
   -- with shift read data_out is valid on
   -- one specific cycle. CPU must read data at exactly this cycle
   capture_proc: process(clk)
   begin
	if (C_clock_range mod 2) = 0 and rising_edge(clk) then
	    R_from_sdram(31 downto 16) <= sdram_data;
	    R_from_sdram(15 downto 0) <= R_from_sdram(31 downto 16);
	end if;
	if (C_clock_range mod 2) = 1 and falling_edge(clk) then
	    R_from_sdram(31 downto 16) <= sdram_data;
	    R_from_sdram(15 downto 0) <= R_from_sdram(31 downto 16);
	end if;
   end process;
   end generate;

   phased_read: if not C_shift_read generate
   -- with phased read data_out keeps valid a
   -- until next read, CPU can read it at any later
   -- time
   phase_proc: process(clk)
   begin
	if (C_clock_range mod 2) = 0 and rising_edge(clk) then
            if data_ready_delay(2) = '1' then
	        R_from_sdram(15 downto 0) <= sdram_data;
            end if;
            if data_ready_delay(1) = '1' then
	        R_from_sdram(31 downto 16) <= sdram_data;
            end if;
	end if;
	if (C_clock_range mod 2) = 1 and falling_edge(clk) then
            if data_ready_delay(2) = '1' then
	        R_from_sdram(15 downto 0) <= sdram_data;
            end if;
            if data_ready_delay(1) = '1' then
	        R_from_sdram(31 downto 16) <= sdram_data;
            end if;
	end if;
   end process;
   end generate;
   data_out <= R_from_sdram;
   ready_next_cycle <= data_ready_delay(C_ready_point);
   
   main_proc: process(clk)
   begin
      if rising_edge(clk) then
         --captured_data_last <= captured_data;
      
         ------------------------------------------------
         -- Default state is to do nothing
         ------------------------------------------------
         iob_command     <= CMD_NOP;
         iob_address     <= (others => '0');
         iob_bank        <= (others => '0');

         ------------------------------------------------
         -- countdown for initialisation & refresh
         ------------------------------------------------
         startup_refresh_count <= startup_refresh_count+1;

         -------------------------------------------------------------------
         -- It we are ready for a new tranasction and one is being presented
         -- then accept it. Also remember what we are reading or writing,
         -- and if it can be back-to-backed with the last transaction
         -------------------------------------------------------------------
         if ready_for_new = '1' and cmd_enable = '1'
           and request_done -- don't allow new transaction until previous one completes
           then
            if save_bank = addr_bank and save_row = addr_row then
               can_back_to_back <= '1';
            else
               can_back_to_back <= '0';
            end if;
            save_row         <= addr_row;
            save_bank        <= addr_bank;
            save_col         <= addr_col;
            save_wr          <= cmd_wr;
            save_data_in     <= cmd_data_in;
            save_byte_enable <= cmd_byte_enable;
            ready_for_new    <= '0';
            request_done <= false; -- this is mis-nomer, used also as write done
            if cmd_wr = '1' then
	       data_ready_delay(C_write_ready_delay) <= '1'; -- schedule write acknowledge
            end if;
         end if;

         ------------------------------------------------
         -- Handle the data coming back from the
         -- SDRAM for the Read transaction
         ------------------------------------------------
         if data_ready_delay(C_done_point) = '1' then
	    request_done <= true;
         end if;
         
         ----------------------------------------------------------------------------
         -- update shift registers used to choose when to present data to/from memory
         ----------------------------------------------------------------------------
         data_ready_delay <= '0' & data_ready_delay(data_ready_delay'high downto 1);
         --ready_next_cycle <= data_ready_delay(C_ready_point);
         iob_dqm          <= dqm_sr(1 downto 0);
         dqm_sr           <= "11" & dqm_sr(dqm_sr'high downto 2);
         
         case state is
            when s_startup =>
               ------------------------------------------------------------------------
               -- This is the initial startup state, where we wait for at least 100us
               -- before starting the start sequence
               -- 
               -- The initialisation is sequence is 
               --  * de-assert SDRAM_CKE
               --  * 100us wait, 
               --  * assert SDRAM_CKE
               --  * wait at least one cycle, 
               --  * PRECHARGE
               --  * wait 2 cycles
               --  * REFRESH, 
               --  * tREF wait
               --  * REFRESH, 
               --  * tREF wait 
               --  * LOAD_MODE_REG 
               --  * 2 cycles wait
               ------------------------------------------------------------------------
               iob_CKE <= '1';
               
               -- All the commands during the startup are NOPS, except these
               if startup_refresh_count = startup_refresh_max-31 then
                  -- ensure all rows are closed
                  iob_command     <= CMD_PRECHARGE;
                  iob_address(prefresh_cmd) <= '1';  -- all banks
                  iob_bank        <= (others => '0');
               elsif startup_refresh_count = startup_refresh_max-23 then
                  -- these refreshes need to be at least tREF (66ns) apart
                  iob_command     <= CMD_REFRESH;
               elsif startup_refresh_count = startup_refresh_max-15 then
                  iob_command     <= CMD_REFRESH;
               elsif startup_refresh_count = startup_refresh_max-7 then
                  -- Now load the mode register
                  iob_command     <= CMD_LOAD_MODE_REG;
		  if C_cas = 2 then
			iob_address <= MODE_REG_CAS_2;
		  else
			iob_address <= MODE_REG_CAS_3;
		  end if;
               end if;

               ------------------------------------------------------
               -- if startup is coomplete then go into idle mode,
               -- get prepared to accept a new command, and schedule
               -- the first refresh cycle
               ------------------------------------------------------
               if startup_refresh_count = 0 then
                  state           <= s_idle;
                  ready_for_new   <= '1';
                  request_done	  <= true;
                  startup_refresh_count <= to_unsigned(2048 - cycles_per_refresh+1,14);
               end if;
               
            when s_idle_in_6 => state <= s_idle_in_5;
            when s_idle_in_5 => state <= s_idle_in_4;
            when s_idle_in_4 => state <= s_idle_in_3;
            when s_idle_in_3 => state <= s_idle_in_2;
            when s_idle_in_2 => state <= s_idle_in_1;
            when s_idle_in_1 => 
               state <= s_idle;

            when s_idle =>
               -- Priority is to issue a refresh if one is outstanding
               if pending_refresh = '1' or forcing_refresh = '1' then
                 ------------------------------------------------------------------------
                  -- Start the refresh cycle.
                  -- This tasks tRFC (66ns), so 6 idle cycles are needed @ 100MHz
                  ------------------------------------------------------------------------
                  state       <= s_idle_in_6;
                  iob_command <= CMD_REFRESH;
                  startup_refresh_count <= startup_refresh_count - cycles_per_refresh+1;
               elsif ready_for_new = '0' then
                  --------------------------------
                  -- Start the read or write cycle.
                  -- First task is to open the row
                  --------------------------------
                  if C_ras = 2 then
                      state <= s_open_in_1;
                  else
                      state <= s_open_in_2;
		  end if;
                  iob_command <= CMD_ACTIVE;
                  iob_address <= save_row;
                  iob_bank    <= save_bank;
               end if;

            --------------------------------------------
            -- Opening the row ready for reads or writes
            --------------------------------------------
            when s_open_in_2 => state <= s_open_in_1;

            when s_open_in_1 =>
               -- still waiting for row to open
               if save_wr = '1' then
                  state       <= s_write_1;
                  iob_dq_hiz  <= '0';
                  iob_data    <= save_data_in(15 downto 0); -- get the DQ bus out of HiZ early
               else
                  iob_dq_hiz  <= '1';
                  state       <= s_read_1;
               end if;
               -- we will be ready for a new transaction next cycle!
               ready_for_new   <= '1';

            ----------------------------------
            -- Processing the read transaction
            ----------------------------------
            when s_read_1 =>
               state           <= s_read_2;
               iob_command     <= CMD_READ;
               iob_address     <= save_col;
               iob_bank        <= save_bank;
               iob_address(prefresh_cmd) <= '0'; -- A10 actually matters - it selects auto precharge

               -- Schedule reading the data values off the bus
               data_ready_delay(data_ready_delay'high)   <= '1';

               -- Set the data masks to read all bytes
               iob_dqm            <= (others => '0');
               dqm_sr(1 downto 0) <= (others => '0');

            when s_read_2 =>
               state <= s_read_3;
               if C_cas = 3 then
                   dqm_sr(1 downto 0) <= (others => '0');
               end if;
               if S_let_back_to_back then
                  if save_wr = '0' then
                     state           <= s_read_1;
                     ready_for_new   <= '1'; -- we will be ready for a new transaction next cycle!
                  end if;
               end if;

            when s_read_3 =>
               if C_cas = 2 then
                   state <= s_precharge;
               else
                   state <= s_read_4;
               end if;
               if S_let_back_to_back then
                  if save_wr = '0' then
                     state           <= s_read_1;
                     ready_for_new   <= '1'; -- we will be ready for a new transaction next cycle!
                  end if;
               end if;

            when s_read_4 =>
               state <= s_precharge;
               -- can we do back-to-back read?
               if S_let_back_to_back then
                  if save_wr = '0' then
                     state           <= s_read_1;
                     ready_for_new   <= '1'; -- we will be ready for a new transaction next cycle!
                  else
                     state <= s_open_in_2; -- we have to wait for the read data to come back before we swutch the bus into HiZ
                  end if;
               end if;

            ------------------------------------------------------------------
            -- Processing the write transaction
            -------------------------------------------------------------------
            when s_write_1 =>
               state              <= s_write_2;
               iob_command        <= CMD_WRITE;
               iob_address        <= save_col;
               iob_address(prefresh_cmd)    <= '0'; -- A10 actually matters - it selects auto precharge
               iob_bank           <= save_bank;
               iob_dqm            <= NOT save_byte_enable(1 downto 0);
               dqm_sr(1 downto 0) <= NOT save_byte_enable(3 downto 2);
               iob_data           <= save_data_in(15 downto 0);
               iob_data_next      <= save_data_in(31 downto 16);

            when s_write_2 =>
               state           <= s_write_3;
               iob_data        <= iob_data_next;
               -- can we do a back-to-back write?
               if S_let_back_to_back then
                  if save_wr = '1' then
                     -- back-to-back write?
                     state           <= s_write_1;
                     ready_for_new   <= '1';
                  end if;
                  -- Although it looks right in simulation you can't go write-to-read 
                  -- here due to bus contention, as iob_dq_hiz takes a few ns.
               end if;
         
            when s_write_3 =>  -- must wait tRDL, hence the extra idle state
               -- back to back transaction?
               if S_let_back_to_back then
                  ready_for_new   <= '1'; -- we will be ready for a new transaction next cycle!
                  if save_wr = '1' then
                     -- back-to-back write?
                     state           <= s_write_1;
                  else
                     -- write-to-read switch?
                     state           <= s_read_1;
                     iob_dq_hiz      <= '1';
                  end if;
               else
                  iob_dq_hiz         <= '1';
                  state              <= s_precharge;
               end if;

            -------------------------------------------------------------------
            -- Closing the row off (this closes all banks)
            -------------------------------------------------------------------
            when s_precharge =>
               if C_pre = 2 then
                   state <= s_idle_in_2;
               else
                   state <= s_idle_in_3;
               end if;
               iob_command     <= CMD_PRECHARGE;
               iob_address(prefresh_cmd) <= '1'; -- A10 actually matters - it selects all banks or just one

            -------------------------------------------------------------------
            -- We should never get here, but if we do then reset the memory
            -------------------------------------------------------------------
            when others =>
               state                 <= s_startup;
               ready_for_new         <= '0';
               startup_refresh_count <= startup_refresh_max-to_unsigned(sdram_startup_cycles,14);
         end case;

         if reset = '1' then  -- Sync reset
            state                 <= s_startup;
            ready_for_new         <= '0';
            startup_refresh_count <= startup_refresh_max-to_unsigned(sdram_startup_cycles,14);
         end if;
      end if;      
   end process;
end Behavioral;