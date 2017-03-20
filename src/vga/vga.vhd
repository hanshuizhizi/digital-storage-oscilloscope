library ieee;
library lpm;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use lpm.lpm_components.all;

entity vga is
    generic (
        READ_ADDR_WIDTH : integer := 9;
        READ_DATA_WIDTH : integer := 12
    );
    port (
        clock : in std_logic;
        reset : in std_logic;
        mem_bus_grant : in std_logic;
        mem_data : in std_logic_vector(READ_DATA_WIDTH - 1 downto 0);
        mem_bus_acquire : out std_logic;
        mem_address : out std_logic_vector(READ_ADDR_WIDTH - 1 downto 0);
        pixel_clock : out std_logic;
        rgb : out std_logic_vector(23 downto 0);
        hsync : out std_logic;
        vsync : out std_logic
    );
end vga;

architecture arch of vga is

    component vga_timing_generator is
        generic (
            H_PIXELS : integer   := 800; -- horizontal display width in pixels
            H_PULSE  : integer   := 120; -- horizontal sync pulse width in pixels
            H_BP     : integer   := 56;  -- horizontal back porch width in pixels
            H_FP     : integer   := 64;  -- horizontal front porch width in pixels
            H_POL    : std_logic := '1'; -- horizontal sync pulse polarity (1 = positive, 0 = negative)
            V_PIXELS : integer   := 600; -- vertical display width in rows
            V_PULSE  : integer   := 6;   -- vertical sync pulse width in rows
            V_BP     : integer   := 37;  -- vertical back porch width in rows
            V_FP     : integer   := 23;  -- vertical front porch width in rows
            V_POL    : std_logic := '1'  -- vertical sync pulse polarity (1 = positive, 0 = negative)
        );
        port (
            clock   : in  std_logic; -- pixel clock at frequency of VGA mode being used
            reset   : in  std_logic; -- asynchronous reset
            row     : out integer range 0 to V_PIXELS - 1; -- vertical pixel coordinate
            column  : out integer range 0 to H_PIXELS - 1; -- horizontal pixel coordinate
            hsync   : out std_logic; -- horizontal sync pulse
            vsync   : out std_logic; -- vertical sync pulse
            blank_n : out std_logic -- active low blanking output
        );
    end component;

    component vga_rom is
        generic (
            X0 : integer;
            Y0 : integer;
            PLOT_HEIGHT : integer;
            PLOT_WIDTH : integer
        );
        port (
            clock : in std_logic;
            reset : in std_logic;
            row : in integer range 0 to 599;
            column : in integer range 0 to 799;
            horizontal_scale : in std_logic_vector(15 downto 0) := (others => '0'); -- BCD in us/div
            vertical_scale : in std_logic_vector(15 downto 0) := x"0512"; -- BCD in mV/div
            trigger_type : in std_logic := '0'; -- '1' for rising edge, '0' for falling edge
            trigger_frequency : in std_logic_vector(15 downto 0) := (others => '0'); -- BCD in 100Hz increments
            voltage_pp : in std_logic_vector(15 downto 0) := (others => '0'); -- BCD in mV
            voltage_avg : in std_logic_vector(15 downto 0) := (others => '0'); -- BCD in mV
            voltage_max : in std_logic_vector(15 downto 0) := (others => '0'); -- BCD in mV
            voltage_min : in std_logic_vector(15 downto 0) := (others => '0'); -- BCD in mV
            rgb : out std_logic_vector(23 downto 0)
        );
    end component;

    component vga_buffer is
        generic (
            V_POL : std_logic := '1';
            PLOT_HEIGHT : integer := 512;
            PLOT_WIDTH : integer := 512;
            READ_ADDR_WIDTH : integer := 9;
            READ_DATA_WIDTH : integer := 12
        );
        port (
            clock : in std_logic;
            reset : in std_logic;
            display_time : in integer range 0 to PLOT_WIDTH - 1;
            vsync : in std_logic;
            mem_bus_grant : in std_logic;
            mem_data : in std_logic_vector(READ_DATA_WIDTH - 1 downto 0);
            mem_bus_acquire : out std_logic;
            mem_address : out std_logic_vector(READ_ADDR_WIDTH - 1 downto 0);
            data_1 : out integer range 0 to PLOT_HEIGHT - 1;
            data_2 : out integer range 0 to PLOT_HEIGHT - 1
        );
    end component;

    constant H_PIXELS : integer   := 800; -- horizontal display width in pixels
    constant H_PULSE  : integer   := 120; -- horizontal sync pulse width in pixels
    constant H_BP     : integer   := 56;  -- horizontal back porch width in pixels
    constant H_FP     : integer   := 64;  -- horizontal front porch width in pixels
    constant H_POL    : std_logic := '1'; -- horizontal sync pulse polarity (1 = positive, 0 = negative)
    constant V_PIXELS : integer   := 600; -- vertical display width in rows
    constant V_PULSE  : integer   := 6;   -- vertical sync pulse width in rows
    constant V_BP     : integer   := 37;  -- vertical back porch width in rows
    constant V_FP     : integer   := 23;  -- vertical front porch width in rows
    constant V_POL    : std_logic := '1'; -- vertical sync pulse polarity (1 = positive, 0 = negative)
    constant BIT_LENGTH : integer := integer(ceil(log2(real(H_PIXELS * V_PIXELS))));

    -- start coordinates for the waveform plot (bottom-left corner)
    constant X0 : integer := 11;
    constant Y0 : integer := 11;
    -- waveform plot dimensions
    constant PLOT_WIDTH : integer := 512;
    constant PLOT_HEIGHT : integer := 512;

    constant YELLOW : std_logic_vector(23 downto 0) := x"FFFF00";

    signal row : integer range 0 to V_PIXELS - 1;
    signal column : integer range 0 to H_PIXELS - 1;
    signal row_delayed : integer range 0 to V_PIXELS - 1;
    signal column_delayed : integer range 0 to H_PIXELS - 1;
    signal hsync_internal : std_logic;
    signal hsync_delayed : std_logic;
    signal vsync_internal : std_logic;
    signal vsync_delayed : std_logic;
    signal blank_n : std_logic;
    signal blank_n_delayed : std_logic;
    signal blank_n_delayed2 : std_logic;

    signal rom_address : std_logic_vector(BIT_LENGTH - 1 downto 0);
    signal background_grayscale : std_logic_vector(3 downto 0);
    signal background_rgb : std_logic_vector(23 downto 0);

    signal display_time : integer range 0 to PLOT_WIDTH - 1;
    signal data_1, data_2 : integer range 0 to PLOT_HEIGHT - 1 := 0;
    signal display_data : std_logic;
    signal display_data_delayed : std_logic;

begin

    timing_generator : vga_timing_generator
        generic map (
            H_PIXELS => H_PIXELS,
            H_PULSE  => H_PULSE,
            H_BP     => H_BP,
            H_FP     => H_FP,
            H_POL    => H_POL,
            V_PIXELS => V_PIXELS,
            V_PULSE  => V_PULSE,
            V_BP     => V_BP,
            V_FP     => V_FP,
            V_POL    => V_POL
        )
        port map (
            clock => clock,
            reset => reset,
            row => row,
            column => column,
            hsync => hsync_internal,
            vsync => vsync_internal,
            blank_n => blank_n
        );

    background : vga_rom
        generic map (
            X0 => X0,
            Y0 => Y0,
            PLOT_WIDTH => PLOT_WIDTH,
            PLOT_HEIGHT => PLOT_HEIGHT
        )
        port map (
            clock => clock,
            reset => reset,
            row => row,
            column => column,
            rgb => background_rgb
        );

    buff : vga_buffer
        generic map (
            V_POL => V_POL,
            PLOT_HEIGHT => PLOT_HEIGHT,
            PLOT_WIDTH => PLOT_WIDTH,
            READ_ADDR_WIDTH => READ_ADDR_WIDTH,
            READ_DATA_WIDTH => READ_DATA_WIDTH
        )
        port map (
            clock => clock,
            reset => reset,
            display_time => display_time,
            vsync => vsync_internal,
            mem_bus_grant => mem_bus_grant,
            mem_data => mem_data,
            mem_bus_acquire => mem_bus_acquire,
            mem_address => mem_address,
            data_1 => data_1,
            data_2 => data_2
        );

    display_time <= column - X0 when (column >= X0 and column < X0 + PLOT_WIDTH) else
        PLOT_WIDTH - 1;

    range_comparator : process (data_1, data_2, row_delayed, column_delayed)
        variable data_row : integer range -Y0 to V_PIXELS - 1 - Y0;
    begin
        -- convert the row to the equivalent on the waveform plot
        data_row := V_PIXELS - 1 - row_delayed - Y0;

        display_data <= '0'; -- default output
        if ((column_delayed >= X0 and column_delayed < X0 + PLOT_WIDTH) and
            ((data_row >= data_1 and data_row <= data_2) or
            (data_row <= data_1 and data_row >= data_2))) then
            display_data <= '1';
        end if;
    end process;

    display_mux : process (display_data_delayed, blank_n_delayed2, background_rgb)
    begin
        if (blank_n_delayed2 = '0') then
            rgb <= (others => '0');
        elsif (display_data_delayed = '1') then
            rgb <= YELLOW;
        else
            rgb <= background_rgb;
        end if;
    end process;

    delay_registers : process (clock, reset)
    begin
        if (reset = '1') then
            row_delayed <= 0;
            column_delayed <= 0;
            display_data_delayed <= '0';
            blank_n_delayed <= '0';
            blank_n_delayed2 <= '0';
            hsync_delayed <= '0';
            hsync <= '0';
            vsync_delayed <= '0';
            vsync <= '0';
        elsif (rising_edge(clock)) then
            row_delayed <= row;
            column_delayed <= column;
            display_data_delayed <= display_data;
            blank_n_delayed <= blank_n;
            blank_n_delayed2 <= blank_n_delayed;
            hsync_delayed <= hsync_internal;
            hsync <= hsync_delayed;
            vsync_delayed <= vsync_internal;
            vsync <= vsync_delayed;
        end if;
    end process;

    pixel_clock <= clock;

end architecture;