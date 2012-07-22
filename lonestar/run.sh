
# Set up local executables and libraries
tar -xf lib.tgz
tar -xf vcftools.tgz

REFERENCE=${databaseFasta}
SAM=${alignFile}
CPUS=${IPLANT_CORES_REQUESTED}

# Vars passed in from outside
# REFERENCE=/iplant/home/shared/1000bulls/umd_3_1/genome.fa
# SAM or BAM file is allowed
# SAM=bwa_output.sam

PLAT="illumina"
SID="ANIMAL01"
LIB=1
CENTER=""
STAND_CALL_CONF=4.0
DCOV=5

if [ -n "${platform}" ]; then PLAT=${platform}; fi
if [ -n "${sampleid}" ]; then SID=${sampleid}; fi
if [ -n "${library}" ]; then LIB=${library}; fi
if [ -n "${center}" ]; then CENTER=${center}; fi
if [ -n "${stand_call_conf}" ]; then STAND_CALL_CONF=${stand_call_conf}; fi
if [ -n "${dcov}" ]; then DCOV=${dcov}; fi

VCF1="GATK.SNPS.vcf"
VCF2="GATK.INDELS.vcf"
VCF3="GATK.BOTH.vcf"

# Bring over reference sequence and generate its faidx
#
# Copy reference sequence.
REFERENCE_F=$(basename ${REFERENCE})
echo "Copying $REFERENCE_F"
iget -frPVT ${REFERENCE} .

# Index the genome sequence
samtools faidx $REFERENCE_F
# Build a sequence dictionary for the genome sequence
REFERENCE_BASE=${REFERENCE_F%.*}
java -Xms768m -Xmx1945m -jar $TACC_PICARD_DIR/CreateSequenceDictionary.jar REFERENCE=$REFERENCE_F OUTPUT=${REFERENCE_BASE}.dict

# Copy SAM alignment
SAM_F=$(basename ${SAM})
echo "Copying $SAM_F"
iget -frPVT ${SAM} .

# Filter SAM to remove unmapped reads

if [[ $SAM_F =~ ".bam$" ]];
then
	echo "Autodetected BAM"
	samtools view -F 4 -bu $SAM_F > bwa_output.bam
else
	echo "Autodetected BAM"
	samtools view -F 4 -bSu $SAM_F > bwa_output.bam
fi

# AddOrReplaceReadGroups and, as bonus, sort and index
java -jar $TACC_PICARD_DIR/AddOrReplaceReadGroups.jar COMPRESSION_LEVEL=1 INPUT=bwa_output.bam OUTPUT=picard_output.bam SORT_ORDER=coordinate CREATE_INDEX=true VALIDATION_STRINGENCY=SILENT RGLB=${LIB} RGPL=${PLAT} RGPU=allruns RGSM=${SID} RGCN=${CENTER}

# Compute coverage. Deprecated for now until I get
# verification of why it is done
#
#java -Xmx12G -jar $TACC_GATK_DIR/GenomeAnalysisTK.jar --num_threads 12 -R $REFERENCE_F -T DepthOfCoverage -o "coverage.txt" -I picard_output.bam  --omitDepthOutputAtEachBase --omitIntervalStatistics --omitLocusTable

# Build interval file and turn into a parameter list
#
# A key element here is the max heap size: 23.5 / 12 = 1.95 GB
# Another key element is the wayness - we are able to run up to 8 threads at this
# heap size leaving 4 cores unoccupied
# 
# Another element is that I need to compute the coverage values from the
# DepthOfCoverage output. Right now it's being passed in hard-coded
#

# Temp directories
mkdir -p vcf_snp_tmp
mkdir -p vcf_indel_tmp
mkdir -p vcf_both_tmp

# Automatically generate interval file
# Warning: BED is zero indexed
# 10 MB intervals 
bedtools makewindows -g ${REFERENCE_F}.fai -w 10000000 > intervals.txt

# Create paramlist for Launcher

awk -v AAA=$DCOV -v BBB=$STAND_CALL_CONF -v CCC=${REFERENCE_F} '{print "java -Xms768m -Xmx1945m -jar $TACC_GATK_DIR/GenomeAnalysisTK.jar -L", $1":"($2+1)"-"($3+0)," -o vcf_both_tmp/${RANDOM}_${RANDOM}.vcf -R "CCC" -T UnifiedGenotyper -I picard_output.bam -stand_call_conf "BBB" -dcov "AAA" -glm BOTH";}' intervals.txt > paramlist.BOTH

# Run SNP and INDEL calling via Launcher
EXECUTABLE=$TACC_LAUNCHER_DIR/init_launcher
# Run the commands in paramlist.aln
echo "Calling variants"
$TACC_LAUNCHER_DIR/paramrun $EXECUTABLE paramlist.BOTH

# Merge, then sort the VCFs using VCFtools. 
# These have perl mod dependencies, hence the provision 
# of the lib/ folder
#
ARGS=
for C in vcf_both_tmp/*.vcf; do ARGS="$ARGS $C"; done
./vcftools/bin/vcf-concat $ARGS | ./vcftools/bin/vcf-sort > $VCF3

# Split the VCF into SNV and INDEL calls, including full headers
awk -f filter.awk $VCF3
mv snv.vcf $VCF1
mv indels.vcf $VCF2

# clean up _tmp
rm -rf vcf_both_tmp vcf_indel_tmp vcf_snp_tmp bwa_output.bam picard_* intervals.txt paramlist.* vcftools *.pm genome.*
