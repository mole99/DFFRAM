#!/bin/bash
<<HEREDOC > /dev/null
example.sh
--
This is an example flow for use with placeRAM.

There is a support tarball included for this file that is checked into the
repository.

It goes all the way from elaborating the custom Verilog netlists to LVS.

This script requires docker and will pull openlane and other dependencies.
If you would not like to use either, feel free to substitute any of the
invocations with local ones.
HEREDOC

if [ ! -d ./example_support ]; then
     echo "Untarring support files…"
     tar -xJf ./example/example_support.tar.xz
fi

set -e
set -x

export SIZE="${SIZE:-8x32}"
export DESIGN=RAM$SIZE

export MARGIN=5

# ---
BUILD_FOLDER=./build/$DESIGN
export DESIGN_WIDTH=1000
export DESIGN_HEIGHT=1000

(( FULL_WIDTH=$DESIGN_WIDTH + $MARGIN ))
(( FULL_HEIGHT=$DESIGN_HEIGHT + $MARGIN ))

# ---
DOCKER_INTERACTIVE="0"
openlane() {
     DOCKER_TI_FLAG=""
     if [ "$DOCKER_INTERACTIVE" = "1" ]; then
          DOCKER_TI_FLAG="-ti"
     fi
     docker run $DOCKER_TI_FLAG\
          -v $(realpath ..):/mnt/dffram\
          -w /mnt/dffram/Compiler\
          efabless/openlane\
          $@
}

placeram() {
    docker run --rm\
         -v $(realpath ..):/mnt/dffram\
         -w /mnt/dffram/Compiler\
         cloudv/dffram-env\
         python3 -m placeram\
         --represent $BUILD_FOLDER/$DESIGN.txt\
         --output $BUILD_FOLDER/$DESIGN.placed.def\
         --lef ./example_support/sky130_fd_sc_hd.lef\
         --tech-lef ./example_support/sky130_fd_sc_hd.tlef\
         --size $SIZE\
         $BUILD_FOLDER/$DESIGN.def

    # Remove ports
    rm -f $BUILD_FOLDER/$DESIGN.placed.def.ref
    mv $BUILD_FOLDER/$DESIGN.placed.def $BUILD_FOLDER/$DESIGN.placed.def.ref
    sed 's/+ PORT//g' $BUILD_FOLDER/$DESIGN.placed.def.ref > $BUILD_FOLDER/$DESIGN.placed.def

}

update_width_height(){
    FULL_WIDTH=$(echo "$CORE_WIDTH_POSTPLACEMENT + $MARGIN" | bc)
    FULL_HEIGHT=$(echo "$CORE_HEIGHT_POSTPLACEMENT + $MARGIN" | bc)
}

write_fp_tcl() {
    CORE_WIDTH_HEIGHT_POSTPLACEMENT_FILE=$BUILD_FOLDER/core_width_height_postplacement

    if [[ -f $CORE_WIDTH_HEIGHT_POSTPLACEMENT_FILE ]]
    then
        OLDIFS=$IFS
        IFS=","
        read CORE_WIDTH_POSTPLACEMENT CORE_HEIGHT_POSTPLACEMENT < "$CORE_WIDTH_HEIGHT_POSTPLACEMENT_FILE"
        cat $CORE_WIDTH_HEIGHT_POSTPLACEMENT_FILE
        IFS=$OLDIFS
    fi


    CORE_WIDTH_POSTPLACEMENT="${CORE_WIDTH_POSTPLACEMENT:-$DESIGN_WIDTH}"
    CORE_HEIGHT_POSTPLACEMENT="${CORE_HEIGHT_POSTPLACEMENT:-$DESIGN_HEIGHT}"
    update_width_height

    cat <<HEREDOC > $BUILD_FOLDER/fp_init.tcl

    read_liberty ./example_support/sky130_fd_sc_hd__tt_025C_1v80.lib

    read_lef ./example_support/sky130_fd_sc_hd.merged.lef

    read_verilog $BUILD_FOLDER/$DESIGN.gl.v

    link_design $DESIGN

    initialize_floorplan\
         -die_area "0 0 $FULL_WIDTH $FULL_HEIGHT"\
         -core_area "$MARGIN $MARGIN $CORE_WIDTH_POSTPLACEMENT $CORE_HEIGHT_POSTPLACEMENT"\
         -site unithd\
         -tracks ./example_support/sky130hd.tracks

    ppl::set_hor_length 4
    ppl::set_ver_length 4
    ppl::set_hor_length_extend 2
    ppl::set_ver_length_extend 2
    ppl::set_ver_thick_multiplier 4
    ppl::set_hor_thick_multiplier 4

    report_checks -fields {input slew capacitance} -format full_clock

    write_def $BUILD_FOLDER/$DESIGN.def
HEREDOC

}

floorplan() {
    write_fp_tcl
    openlane openroad $BUILD_FOLDER/fp_init.tcl
}

place_pins_manually(){
    MOUNT_PNT=/mnt/dffram/Compiler
    docker run $DOCKER_TI_FLAG\
        -v $(realpath .):$MOUNT_PNT\
        -w /openLANE_flow\
        efabless/openlane\
        python3 ./scripts/io_place.py \
				--input-lef $MOUNT_PNT/example_support/sky130_fd_sc_hd.merged.lef \
				--input-def $MOUNT_PNT/build/$DESIGN/$DESIGN.def \
				--config $MOUNT_PNT/pin_order.cfg \
				--hor-layer 4 \
				--ver-layer 3 \
				--ver-width-mult 2 \
				--hor-width-mult 2 \
				--hor-extension -1 \
				--ver-extension -1 \
				--length 4 \
				-o $MOUNT_PNT/build/$DESIGN/$DESIGN.def
}

mkdir -p ./build/
mkdir -p $BUILD_FOLDER

# 1. Synthesis
cat <<HEREDOC > $BUILD_FOLDER/synth.tcl
# Not true synthesis, just elaboration.

yosys -import

set SCL \$env(LIBERTY)
set DESIGN \$env(DESIGN)

read_liberty -lib -ignore_miss_dir -setattr blackbox \$SCL
read_verilog BB.v

hierarchy -check -top \$DESIGN

synth -top \$DESIGN -flatten

splitnets
opt_clean -purge

write_verilog -noattr -noexpr -nodec $BUILD_FOLDER/\$DESIGN.gl.v
stat -top \$DESIGN -liberty \$SCL

exit
HEREDOC

cat <<HEREDOC > $BUILD_FOLDER/synth.sh
export DESIGN=$DESIGN
export LIBERTY=./example_support/sky130_fd_sc_hd__tt_025C_1v80.lib
yosys $BUILD_FOLDER/synth.tcl
HEREDOC

openlane bash $BUILD_FOLDER/synth.sh

# 2. Floorplan and Place, 2nd time for shrinking
for i in {1..2}
do
    floorplan
    # # Interactive
    # DOCKER_INTERACTIVE=1 openlane openroad

    # PlaceRAM
    place_pins_manually
    placeram

done
# 3. Verify Placement
cat <<HEREDOC > $BUILD_FOLDER/verify.tcl
read_liberty ./example_support/sky130_fd_sc_hd__tt_025C_1v80.lib

read_lef ./example_support/sky130_fd_sc_hd.merged.lef

read_def $BUILD_FOLDER/$DESIGN.placed.def

if [check_placement -verbose] {
    puts "Placement failed: Check placement returned a nonzero value."
    exit 65
}

puts "Placement successful."
HEREDOC

openlane openroad $BUILD_FOLDER/verify.tcl

# 4. Attempt Routing
cat <<HEREDOC > $BUILD_FOLDER/route.tcl
source ./example_support/sky130hd.vars

read_liberty ./example_support/sky130_fd_sc_hd__tt_025C_1v80.lib

read_lef ./example_support/sky130_fd_sc_hd.merged.lef

read_def $BUILD_FOLDER/$DESIGN.placed.def

global_route \
     -guide_file $BUILD_FOLDER/route.guide \
     -layers \$global_routing_layers \
     -clock_layers \$global_routing_clock_layers \
     -unidirectional_routing \
     -overflow_iterations 100

tr::detailed_route_cmd $BUILD_FOLDER/tr.param
HEREDOC

cat <<HEREDOC > $BUILD_FOLDER/tr.param
lef:./example_support/sky130_fd_sc_hd.merged.lef
def:$BUILD_FOLDER/$DESIGN.placed.def
guide:$BUILD_FOLDER/route.guide
output:$BUILD_FOLDER/$DESIGN.routed.def
outputguide:$BUILD_FOLDER/$DESIGN.guide
outputDRC:$BUILD_FOLDER/$DESIGN.drc
threads:8
verbose:1
HEREDOC

openlane openroad $BUILD_FOLDER/route.tcl

# 5. LVS
cat <<HEREDOC > $BUILD_FOLDER/lvs.tcl
puts "Running magic script…"
lef read ./example_support/sky130_fd_sc_hd.merged.lef
def read $BUILD_FOLDER/$DESIGN.routed.def
load $DESIGN -dereference
extract do local
extract no capacitance
extract no coupling
extract no resistance
extract no adjust
extract unique
extract

ext2spice lvs
ext2spice
HEREDOC

# arguments with whitespace work horrendous when passing through a procedure
cat <<HEREDOC > $BUILD_FOLDER/lvs.sh
magic -rcfile ./example_support/sky130A.magicrc -noconsole -dnull < $BUILD_FOLDER/lvs.tcl
mv *.ext *.spice $BUILD_FOLDER
netgen -batch lvs "$BUILD_FOLDER/$DESIGN.spice $DESIGN" "$BUILD_FOLDER/$DESIGN.gl.v $DESIGN" -full
mv comp.out $BUILD_FOLDER/lvs.rpt
HEREDOC

openlane bash $BUILD_FOLDER/lvs.sh

# Harden? # def -> gdsII (magic) and def -> lef (magic)
