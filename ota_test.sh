#!/usr/bin/env bash
# ota_test.sh
#
# Automated Over The Air (OTA) voice test for Radio Autoencoder:
#   + Given an input speech wave file, constructs a compressed SSB and radae signal with 
#     the same average power
#   + Transmits the signal over a radio
#   + Decodes the radae audio and extract SSB for comparison
#
# The Tx radio can be a wave file, or COTS HF radio connected to a sound card with PTT via 
# rigctl. The Rx radio can be a wave file, KiwiSDR, or RTLSDR.
#
# Setup (you may not need all of these):
# --------------------------------------
#
# 1. Install python3, sox, octave, octave signal processing toolbox
# 2. Clone and build codec2-dev/master, as we use a few utilities
#    cd codec2
#    mkdir build_linux
#    cd build_linux
#    cmake -DUNITTEST=1 ..
#    make ch mksine tlininterp
#    (optional if using HackRF) manually compile misc/tsrc 
# 1. (optional) Install HackRF tools:
#      TODO
# 2. (optional) Install kiwclient:
#      TODO - this option not working yet
#      cd ~ && git clone git@github.com:jks-prv/kiwiclient.git
# 3. Hamlib cli tools (rigctl), and add user to dialout group, e.g. for "david" user:
#      sudo apt install libhamlib-utils
#      sudo adduser david dialout
#      logout/log back in and check "groups" includes dialout
# 4. Test rigctl (change model number for your radio):
#      echo "m" | rigctl -m 3061 -r /dev/ttyUSB0
# 5. Adjust HF radio Tx drive so ALC is just being tickled, set desired RF power:
#      ./ota_test.sh wav/david.wav -x
#      aplay -f S16_LE --device="plughw:CARD=CODEC,DEV=0" tx.wav
#
# Usage
# -----
#
# 1. File based I/O example:
#    ./ota_test.sh wav/peter.wav -x 
#    ~/codec2-dev/build_linux/src/ch tx.wav - --No -20 | sox -t .s16 -r 8000 -c 1 - rx.wav
#    ./ota_test.sh -r rx.wav
#    aplay rx_ssb.wav rx_radae.wav
#
# 2. Use HackRF to Tx SSB + radae at 144.5 MHz
#    ./ota_test.sh wav/peter.wav -x
#    hackrf_transfer -t tx.iq8 -s 4E6 -f 143.5E6 -R
#    Note tx.iq8 has at +1 MHz offset, so we tune the HackRF 1 MHz low
#  
# 3. HF Radio Tx, KiwiSDR Rx, vk5dgr_testing_8k.wav as station ID file:
#    ./ota_test.sh wav/peter.wav -i ~/Downloads/vk5dgr_testing_8k.wav sdr.ironstonerange.com -p 8074

CODEC2_PATH=${HOME}/codec2-dev
# TODO: way to adjust /build_linux/src for OSX
PATH=${PATH}:${CODEC2_PATH}/build_linux/src:${CODEC2_PATH}/build_linux/misc:${HOME}/kiwiclient

which ch || { printf "\n**** Can't find ch - check CODEC2_PATH **** \n\n"; exit 1; }

kiwi_url=""
port=8074
freq_kHz="7177"
tx_only=0
Nbursts=5
model=3061
gain=6
serialPort="/dev/ttyUSB0"
rxwavefile=0
soundDevice="plughw:CARD=CODEC,DEV=0"
tx_file_only=0
stationid=""
speechFs=16000
setpoint_rms=6000
setpoint_peak=16384
freq_offset=0
peak=1

source utils.sh

function print_help {
    echo
    echo "Automated Over The Air (OTA) voice test for Radio Autoencoder"
    echo
    echo "  usage ./ota_test.sh -x InputSpeechWaveFile"
    echo "  usage ./ota_test.sh -r rxWaveFile"
    echo "  or:"
    echo "  usage ./ota_voice_test.sh [options] SpeechWaveFile [kiwi_url]"
    echo
    echo "    -c dev                    The sound device (in ALSA format on Linux, CoreAudio for macOS)"
    echo "    -d                        debug mode; trace script execution"
    echo "    -g                        SSB (analog) compressor gain"
    echo "    -i StationIDWaveFile      Prepend this file to identify transmission (should be 8kHz mono)"
    echo "    -o model                  select radio model number ('rigctl -l' to list)"
    echo "    -p port                   kiwi_url port to use (default 8073)"
    echo "    -r                        Rx wave file mode: Rx process supplied rx wave file"
    echo "    -s SerialPort             The serial port (or hostname:port) to control SSB radio,"
    echo "                              default /dev/ttyUSB0"
    echo "    -t                        Tx only, useful for manually observing SDRs"
    echo "    -x                        Generate tx.raw, tx.wav, tx.iq8 files and exit"
    echo "    --rms                     Equalise RMS power of RADAE and SSB (default is equalpeak power)"
    echo
    exit
}


function run_rigctl {
    command=$1
    model=$2
    echo $command | rigctl -m $model -r $serialPort > /dev/null
    if [ $? -ne 0 ]; then
        echo "Can't talk to Tx"
        clean_up
        exit 1
    fi
}

function clean_up {
    echo "killing KiwiSDR process"
    kill ${kiwi_pid}
    wait ${kiwi_pid} 2>/dev/null
    exit 1
}

function process_rx {
    echo "Process receiver sample"
    # Place results in same path, same file name as inpout file
    filename="${1%.*}"
     
    rx=$(mktemp).wav
    sox $1 -c 1 -r 8k $rx
    # generate spectrogram
    echo "pkg load signal; warning('off', 'all'); \
          s=load_raw('$rx'); \
          plot_specgram(s, 8000, 200, 3000); print('${filename}_spec.jpg', '-djpg'); \
          quit" | octave-cli -p ${CODEC2_PATH}/octave -qf > /dev/null
    
    # extract sine wave at start and estimate C/No
    rx_sine=$(mktemp).f32
    sox $rx -e float -b 32 -c 2 ${rx_sine} trim 0 1
    python3 est_CNo.py  ${rx_sine}

    # assume first half is voice, so extract that, and decode radae
    total_duration=$(sox --info -D $rx)
    end_ssb=$(python3 -c "x=(${total_duration}-4)/2+1; print(\"%f\" % x)")
    rx_radae=$(mktemp)
    sox $rx ${filename}_ssb.wav trim 3 $end_ssb
    sox $rx -e float -b 32 -c 2 ${rx_radae}.f32 trim $end_ssb remix 1 0
    ./rx.sh model17/checkpoints/checkpoint_epoch_100.pth ${rx_radae}.f32 ${filename}_radae.wav --pilots --pilot_eq --bottleneck 3 --cp 0.004 --coarse_mag --time_offset -16
}


POSITIONAL=()
while [[ $# -gt 0 ]]
do
key="$1"
case $key in
    -d)
        set -x	
        shift
    ;;
    -f)
        freq_kHz="$2"	
        shift
        shift
    ;;
    --freq_offset)
        freq_offset="$2"	
        shift
        shift
    ;;
    -g)
        gain="$2"	
        shift
        shift
    ;;
    -i)
        stationid="$2"	
        shift
        shift
    ;;
    -o)
        model="$2"	
        shift
        shift
    ;;
    -p)
        port="$2"	
        shift
        shift
    ;;
    --rms)
        peak=0
        shift
    ;;
    -t)
        tx_only=1	
        shift
    ;;
    -r)
        rxwavefile=1	
        shift
    ;;
    -x)
        tx_file_only=1	
        shift
    ;;
    -c)
        soundDevice="$2"
        shift
        shift
    ;;
    -s)
        serialPort="$2"
        shift
        shift
    ;;
    -h)
        print_help	
    ;;
    *)
    POSITIONAL+=("$1") # save it in an array for later
    shift
    ;;
esac
done
set -- "${POSITIONAL[@]}" # restore positional parameters

speechFs=16000

if [ $rxwavefile -eq 1 ]; then
    process_rx $1 $freq_offset
    exit 0
fi

speechfile="$1"
if [ ! -f $speechfile ]; then
    echo "Can't find input speech wave file: ${speechfile}!"
    exit 1
fi

if [ $tx_only -eq 0 ]; then
    if [ $# -lt 1 ]; then
        print_help
    fi
    kiwi_url="$2"
    echo $kiwi_url
fi

# create Tx file ------------------------

# create 1000 Hz sinewave header used for tuning and C/No est
tx_sine=$(mktemp)
if [ $peak -eq 1 ]; then
    peak_amp=$setpoint_peak
else
    peak_amp=$(python3 -c "import numpy as np; peak_amp=${setpoint_rms}*np.sqrt(2); print(\"%f\" % peak_amp)")
fi
mksine $tx_sine 1000 4 $peak_amp

# create compressed SSB signal
speechfile_raw_8k=$(mktemp)
comp_in=$(mktemp)
tx_ssb=$(mktemp)
tx_radae=$(mktemp)
# With 16kHz input files, we need an 8kHz version for SSB
sox $speechfile -r 8000 -t .s16 -c 1 $speechfile_raw_8k
if [ -z $stationid ]; then
    cp $speechfile_raw_8k $comp_in
else
    # append station ID
    stationid_raw_8k=$(mktemp)
    sox $stationid -r 8000 -t .s16 -c 1 $stationid_raw_8k
    cat  $stationid_raw_8k $speechfile_raw_8k > $comp_in
fi
analog_compressor $comp_in $tx_ssb $gain

# insert an extra second of silence at start of radae speech input to make sync easier
speechfile_pad=$(mktemp).wav
sox $speechfile $speechfile_pad pad 1@0

# create modulated radae signal
./inference.sh model17/checkpoints/checkpoint_epoch_100.pth $speechfile_pad /dev/null --EbNodB 100 --bottleneck 3 --pilots --cp 0.004 --rate_Fs --write_rx ${tx_radae}.f32
# to create real signal we just extract the "left" channel (without remix it sums channels)
sox -r 8k -e float -b 32 -c 2 ${tx_radae}.f32 -t .s16 -c 1 ${tx_radae}.raw remix 1 0

# Make power of both signals the same, by adjusting the levels to meet the setpoint
if [ $peak -eq 1 ]; then
  set_peak $tx_ssb $setpoint_peak
  set_peak ${tx_radae}.raw $setpoint_peak
else
  set_rms $tx_ssb $setpoint_rms
  set_rms ${tx_radae}.raw $setpoint_rms
fi

# insert 1 second of silence between SSB and radae
tx_radae_pad=$(mktemp).raw
sox -t .s16 -r 8k -c 1 ${tx_radae}.raw -t .s16 -r 8k -c 1 $tx_radae_pad pad 1@0

# cat signals together so we can send them over a radio at the same time
cat $tx_sine $tx_ssb $tx_radae_pad > tx.raw
sox -t .s16 -r 8000 -c 1 tx.raw tx.wav

# generate a 4MSP .iq8 file suitable for replaying by HackRF (can disable if not using HackRF)
#ch tx.raw - --complexout | tsrc - - 5 -c | tlininterp - tx.iq8 100 -d -f

# time domain plot of tx signal
#echo "pkg load signal; warning('off', 'all'); \
#       s=load_raw('tx.raw'); plot(s); \
#        print('tx.jpg', '-djpg'); \
#       quit" | octave-cli -p ${CODEC2_PATH}/octave -qf > /dev/null

if [ $tx_file_only -eq 1 ]; then
  exit 0
fi

# kick off KiwiSDR ----------------------------

usb_lsb=$(python3 -c "print('usb') if ${freq_kHz} >= 10000 else print('lsb')")
if [ $tx_only -eq 0 ]; then
    # clean up any kiwiSDR processes if we get a ctrl-C
    trap clean_up SIGHUP SIGINT SIGTERM

    echo -n "waiting for KiwiSDR "
    # start recording from remote kiwisdr
    kiwi_stdout=$(mktemp)
    kiwirecorder.py -s $kiwi_url -p ${port} -f $freq_kHz -m ${usb_lsb} -r 8000 --filename=rx --time-limit=300 >$kiwi_stdout &
    kiwi_pid=$!

    # wait for kiwi to start recording
    timeout_counter=0
    until grep -q -i 'Block: ' $kiwi_stdout
    do
        timeout_counter=$((timeout_counter+1))
        if [ $timeout_counter -eq 10 ]; then
            echo "can't connect to ${kiwi_url}"
            kill ${kiwi_pid}
            wait ${kiwi_pid} 2>/dev/null
            exit 1
        fi
        echo -n "."
        sleep 1
    done
    echo
fi

# transmit using local SSB radio
echo "Tx data signal"
freq_Hz=$((freq_kHz*1000))
usb_lsb_upper=$(echo ${usb_lsb} | awk '{print toupper($0)}')
run_rigctl "\\set_freq ${freq_Hz}" $model
run_rigctl "\\set_ptt 1" $model
if [ `uname` == "Darwin" ]; then
    AUDIODEV="${soundDevice}" play -t raw -b 16 -c 1 -r 8000 -e signed-integer --endian little tx.raw 
else
    aplay --device="${soundDevice}" -f S16_LE tx.raw 2>/dev/null
fi
if [ $? -ne 0 ]; then
    run_rigctl "\\set_ptt 0" $model
    clean_up
    echo "Problem running aplay!"
    echo "Is ${soundDevice} configured as the default sound device in Settings-Sound?"
    exit 1
fi
run_rigctl "\\set_ptt 0" $model

if [ $tx_only -eq 0 ]; then
    sleep 2
    echo "Stopping KiwiSDR"
    kill ${kiwi_pid}
    wait ${kiwi_pid} 2>/dev/null

    process_rx rx.wav
fi

