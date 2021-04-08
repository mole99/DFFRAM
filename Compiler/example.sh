#!/bin/bash
if [ ! -d ./example_support ]; then
     echo "Untarring support files…"
     tar -xJf ./example_support.tar.xz
fi

set -e
set -x

export SIZE=32x32
export DESIGN=RAM$SIZE


export SAFE_ZONE=50

export DESIGN_WIDTH=600
export DESIGN_HEIGHT=600

# ---
BUILD_FOLDER=./build/$DESIGN

(( FULL_SAFE_AREA=$SAFE_ZONE * 2 ))

(( FULL_WIDTH=$DESIGN_WIDTH + $FULL_SAFE_AREA ))
(( FULL_HEIGHT=$DESIGN_HEIGHT + $FULL_SAFE_AREA ))

# ---
DOCKER_INTERACTIVE="0"
openlane() {
     DOCKER_TI_FLAG=""
     if [ "$DOCKER_INTERACTIVE" = "1" ]; then
          DOCKER_TI_FLAG="-ti"
     fi
     docker run $DOCKER_TI_FLAG\
          -v $PDK_ROOT:$PDK_ROOT\
          -v $(realpath ..):/mnt/dffram\
          -w /mnt/dffram/Compiler\
          efabless/openlane\
          $@
}

mkdir -p ./build/
mkdir -p $BUILD_FOLDER

# 1. Synthesis
cat <<HEREDOC > $BUILD_FOLDER/synth.sh
     export DESIGN=$DESIGN
     export LIBERTY=\$(realpath ./example_support/sky130_fd_sc_hd__tt_025C_1v80.lib)
     (cd ../Handcrafted/Models; yosys ../Synth/syn.tcl)
HEREDOC

openlane bash $BUILD_FOLDER/synth.sh

# 2. Floorplan Initialization
cat <<HEREDOC > $BUILD_FOLDER/fp_init.tcl
read_liberty ./example_support/sky130_fd_sc_hd__tt_025C_1v80.lib

read_lef ./example_support/sky130_fd_sc_hd.merged.lef

read_verilog ../Handcrafted/Models/$DESIGN.gl.v

link_design $DESIGN

initialize_floorplan\
     -die_area "0 0 $FULL_WIDTH $FULL_HEIGHT"\
     -core_area "$SAFE_ZONE $SAFE_ZONE $DESIGN_WIDTH $DESIGN_HEIGHT"\
     -site unithd\
     -tracks ./example_support/sky130hd.tracks

ppl::set_hor_length 4
ppl::set_ver_length 4
ppl::set_hor_length_extend 2
ppl::set_ver_length_extend 2
ppl::set_ver_thick_multiplier 4
ppl::set_hor_thick_multiplier 4

place_pins\
     -random \
 	-random_seed 42 \
 	-min_distance 5 \
 	-hor_layers 4\
 	-ver_layers 3

report_checks -fields {input slew capacitance} -format full_clock

write_def $BUILD_FOLDER/$DESIGN.def
HEREDOC

openlane openroad $BUILD_FOLDER/fp_init.tcl

# # Interactive 
# DOCKER_INTERACTIVE=1 openlane openroad

# 3. PlaceRAM
docker run --rm\
     -v $(realpath ..):/mnt/dffram\
     -w /mnt/dffram/Compiler\
     donnio/dffram-env\
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

# 4. Verify Placement
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

# 5. Attempt Routing
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

# 6. LVS
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
netgen -batch lvs "$BUILD_FOLDER/$DESIGN.spice $DESIGN" "../Handcrafted/Models/$DESIGN.gl.v $DESIGN" -full
mv comp.out $BUILD_FOLDER/lvs.rpt
HEREDOC

openlane bash $BUILD_FOLDER/lvs.sh 
     
# Harden? # def -> gdsII (magic) and def -> lef (magic)