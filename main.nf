#!/usr/bin/env nextflow
/*
 * Authors:
 * - Daniel Cook <danielecook@gmail.com>
 *
 */

/*
    Globals
*/

// Define contigs here!
CONTIG_LIST = ["I", "II", "III", "IV", "V", "X", "MtDNA"]
contig_list = Channel.from(CONTIG_LIST)

/* 
    ======
    Params
    ======
*/

date = new Date().format( 'yyyyMMdd' )
params.out = "concordance-${date}"
params.debug = false
params.cores = 4
params.tmpdir = "tmp/"
params.email = ""
params.alignments = "bam"
File reference = new File("${params.reference}")
if (params.reference != "(required)") {
   reference_handle = reference.getAbsolutePath();
} else {
   reference_handle = "(required)"
}

fq_concordance_script = file("fq_concordance.R")

// Debug
if (params.debug == true) {
    println """

        *** Using debug mode ***

    """
    params.bamdir = "${params.out}/bam"
    params.fq_file = "${workflow.projectDir}/test_data/SM_sample_sheet.tsv"
    params.fq_file_prefix = "${workflow.projectDir}/test_data"

} else {
    // The SM sheet that is used is located in the root of the git repo
    params.bamdir = "(required)"
    params.fq_file = "SM_sample_sheet.tsv"
    params.fq_file_prefix = null;
}

File fq_file = new File(params.fq_file);

/* 
    =======================
    Filtering configuration
    =======================
*/

min_depth=3
qual=30
mq=40
dv_dp=0.5

/* 
    ==
    UX
    ==
*/

param_summary = '''

┌─┐┌─┐┌┐┌┌─┐┌─┐┬─┐┌┬┐┌─┐┌┐┌┌─┐┌─┐  ┌┐┌┌─┐
│  │ │││││  │ │├┬┘ ││├─┤││││  ├┤───│││├┤ 
└─┘└─┘┘└┘└─┘└─┘┴└──┴┘┴ ┴┘└┘└─┘└─┘  ┘└┘└  
                                                         
''' + """

    parameters              description                    Set/Default
    ==========              ===========                    =======

    --debug                 Set to 'true' to test          ${params.debug}
    --cores                 Regular job cores              ${params.cores}
    --out                   Directory to output results    ${params.out}
    --fq_file               fastq file (see help)          ${params.fq_file}
    --fq_file_prefix        fastq file (see help)          ${params.fq_file_prefix}
    --reference             Reference Genome               ${params.reference}
    --bamdir                Location for bams              ${params.bamdir}
    --tmpdir                A temporary directory          ${params.tmpdir}
    --email                 Email to be sent results       ${params.email}

    HELP: http://andersenlab.org/dry-guide/pipeline-concordance/

"""

println param_summary

if (params.reference == "(required)" || params.fq_file == "(required)") {

    println """
    The Set/Default column shows what the value is currently set to
    or would be set to if it is not specified (it's default).
    """
    System.exit(1)
}

if (!reference.exists()) {
    println """

    Error: Reference does not exist

    """
    System.exit(1)
}

if (!fq_file.exists()) {
    println """

    Error: fastq sheet does not exist

    """
    System.exit(1)
}

/*
    Fetch fastq files and additional information.
*/
if (params.fq_file_prefix) {
println "Using fq prefix"
fq_file_prefix = fq_file.getParentFile().getAbsolutePath();
fqs = Channel.from(fq_file.collect { it.tokenize( '\t' ) })
             .map { SM, ID, LB, fq1, fq2, seq_folder -> ["${SM}", ID, LB, file("${params.fq_file_prefix}/${fq1}"), file("${params.fq_file_prefix}/${fq2}"), seq_folder] }
             .view()

} else {
fqs = Channel.from(fq_file.collect { it.tokenize( '\t' ) })
         .map { SM, ID, LB, fq1, fq2, seq_folder -> [SM, ID, LB, file("${fq1}"), file("${fq2}"), seq_folder] }
}

process setup_dirs {

    executor 'local'

    publishDir params.out, mode: 'copy'

    input:
        file 'SM_sample_sheet.tsv' from Channel.fromPath(params.fq_file)

    output:
        file("SM_sample_sheet.tsv")

    """
        echo 'Great!'
    """
}


/* 
    =========
    Alignment
    =========
*/

process perform_alignment {

    cpus params.cores

    tag { ID }

    input:
        set SM, ID, LB, fq1, fq2, seq_folder from fqs
    output:
        set val(ID), file("${ID}.bam"), file("${ID}.bam.bai") into fq_bam_set
        set val(SM), file("${ID}.bam"), file("${ID}.bam.bai") into SM_aligned_bams

    
    """
        bwa mem -t ${task.cpus} -R '@RG\\tID:${ID}\\tLB:${LB}\\tSM:${SM}' ${reference_handle} ${fq1} ${fq2} | \\
        sambamba view --nthreads=${task.cpus} --show-progress --sam-input --format=bam --with-header /dev/stdin | \\
        sambamba sort --nthreads=${task.cpus} --show-progress --tmpdir=${params.tmpdir} --out=${ID}.bam /dev/stdin
        sambamba index --nthreads=${task.cpus} ${ID}.bam

        if [[ ! \$(samtools view ${ID}.bam | head -n 10) ]]; then
            exit 1;
        fi
    """
}

fq_bam_set.into { fq_cov_bam; fq_stats_bam; fq_idx_stats_bam }

/* 
    ========
    Coverage
    ========
*/
process coverage_fq {

    tag { ID }

    input:
        set val(ID), file("${ID}.bam"), file("${ID}.bam.bai") from fq_cov_bam
    output:
        file("${ID}.coverage.tsv") into fq_coverage


    """
        bam coverage ${ID}.bam > ${ID}.coverage.tsv
    """
}


process coverage_fq_merge {

    publishDir "${params.out}/fq", mode: 'copy', overwrite: true

    input:
        file fq_set from fq_coverage.toSortedList()

    output:
        file("fq_coverage.full.tsv")
        file("fq_coverage.tsv")

    """
        echo -e 'fq\\tcontig\\tstart\\tend\\tproperty\\tvalue' > fq_coverage.full.tsv
        cat ${fq_set} >> fq_coverage.full.tsv

        cat <(echo -e 'fq\\tcoverage') <( cat fq_coverage.full.tsv | grep 'genome' | grep 'depth_of_coverage' | cut -f 1,6) > fq_coverage.tsv
    """
}

/* 
    ==============
    fq index stats
    ==============
*/

process fq_idx_stats {
    
    tag { ID }

    input:
        set val(ID), file("${ID}.bam"), file("${ID}.bam.bai") from fq_idx_stats_bam
    output:
        file fq_idxstats into fq_idxstats_set

    """
        samtools idxstats ${ID}.bam | awk '{ print "${ID}\\t" \$0 }' > fq_idxstats
    """
}

process fq_combine_idx_stats {

    publishDir "${params.out}/fq", mode: 'copy', overwrite: true

    input:
        file("?.stat.txt") from fq_idxstats_set.toSortedList()

    output:
        file("fq_bam_idxstats.tsv")

    """
        echo -e "SM\\treference\\treference_length\\tmapped_reads\\tunmapped_reads" > fq_bam_idxstats.tsv
        cat *.stat.txt >> fq_bam_idxstats.tsv
    """

}

/* 
    ============
    fq bam stats
    ============
*/
process fq_bam_stats {

    tag { ID }

    input:
        set val(ID), file("${ID}.bam"), file("${ID}.bam.bai") from fq_stats_bam

    output:
        file 'bam_stat' into fq_bam_stat_files

    """
        cat <(samtools stats ${ID}.bam | grep ^SN | cut -f 2- | awk '{ print "${ID}\t" \$0 }' | sed 's/://g') > bam_stat
    """
}

process combine_fq_bam_stats {

    publishDir "${params.out}/fq", mode: 'copy', overwrite: true

    input:
        file("*.stat.txt") from fq_bam_stat_files.toSortedList()

    output:
        file("fq_bam_stats.tsv")

    """
        echo -e "ID\\tvariable\\tvalue\\tcomment" > fq_bam_stats.tsv
        cat *.stat.txt >> fq_bam_stats.tsv
    """
}


/* 
  Merge - Generate SM Bam
*/

process merge_bam {

    cpus params.cores

    publishDir "${params.bamdir}/WI/strain", mode: 'copy', pattern: '*.bam*'

    tag { SM }

    input:
        set SM, bam, index from SM_aligned_bams.groupTuple()

    output:
        set val(SM), file("${SM}.bam"), file("${SM}.bam.bai") into bam_set
        file("${SM}.duplicates.txt") into duplicates_file
        
    """

    count=`echo ${bam.join(" ")} | tr ' ' '\\n' | wc -l`

    if [ "\${count}" -eq "1" ]; then
        ln -s ${bam.join(" ")} ${SM}.merged.bam
        ln -s ${bam.join(" ")}.bai ${SM}.merged.bam.bai
    else
        sambamba merge --nthreads=${task.cpus} --show-progress ${SM}.merged.bam ${bam.sort().join(" ")}
        sambamba index --nthreads=${task.cpus} ${SM}.merged.bam
    fi

    picard MarkDuplicates I=${SM}.merged.bam O=${SM}.bam M=${SM}.duplicates.txt VALIDATION_STRINGENCY=SILENT REMOVE_DUPLICATES=false
    sambamba index --nthreads=${task.cpus} ${SM}.bam
    """
}

bam_set.into { 
               merged_bams_for_coverage;
               merged_bams_individual;
               merged_bams_union;
               bams_idxstats;
               bams_stats;
               fq_concordance_bam
             }


/*
    SM_idx_stats
*/

process SM_idx_stats {
    
    tag { SM }

    input:
        set val(SM), file("${SM}.bam"), file("${SM}.bam.bai") from bams_idxstats
    output:
        file('bam_idxstats.txt') into bam_idxstats_set

    """
        samtools idxstats ${SM}.bam | awk '{ print "${SM}\\t" \$0 }' > bam_idxstats.txt
    """
}

process SM_combine_idx_stats {

    publishDir "${params.out}/strain", mode: 'copy', overwrite: true

    input:
        file("*.stat.txt") from bam_idxstats_set.toSortedList()

    output:
        file("SM_bam_idxstats.tsv")

    """
        echo -e "SM\\treference\\treference_length\\tmapped_reads\\tunmapped_reads" > SM_bam_idxstats.tsv
        cat *.stat.txt | sort >> SM_bam_idxstats.tsv
    """

}


/*
    SM bam stats
*/

process SM_bam_stats {

    tag { SM }

    input:
        set val(SM), file("${SM}.bam"), file("${SM}.bam.bai") from bams_stats

    output:
        file('bam_stat.txt') into SM_bam_stat_files

    """
        cat <(samtools stats ${SM}.bam | grep ^SN | cut -f 2- | awk '{ print "${SM}\t" \$0 }' | sed 's/://g') > bam_stat.txt
    """
}

process combine_SM_bam_stats {

    publishDir "${params.out}/strain", mode: 'copy', overwrite: true

    input:
        file("?.stat.txt") from SM_bam_stat_files.toSortedList()

    output:
        file("SM_bam_stats.tsv")

    """
        echo -e "ID\\tvariable\\tvalue\\tcomment" > SM_bam_stats.tsv
        cat *.stat.txt | sort >> SM_bam_stats.tsv
    """
}



process format_duplicates {

    publishDir "${params.out}/duplicates", mode: 'copy', overwrite: true

    input:
        val duplicates_set from duplicates_file.toSortedList()

    output:
        file("bam_duplicates.tsv")


    """
        echo -e 'filename\\tlibrary\\tunpaired_reads_examined\\tread_pairs_examined\\tsecondary_or_supplementary_rds\\tunmapped_reads\\tunpaired_read_duplicates\\tread_pair_duplicates\\tread_pair_optical_duplicates\\tpercent_duplication\\testimated_library_size' > bam_duplicates.tsv
        for i in ${duplicates_set.join(" ")}; do
            f=\$(basename \${i})
            cat \${i} | awk -v f=\${f/.duplicates.txt/} 'NR >= 8 && \$0 !~ "##.*" && \$0 != ""  { print f "\\t" \$0 } NR >= 8 && \$0 ~ "##.*" { exit }'  >> bam_duplicates.tsv
        done;
    """
}

/*
    Coverage Bam
*/
process coverage_SM {

    tag { SM }

    input:
        set val(SM), file("${SM}.bam"), file("${SM}.bam.bai") from merged_bams_for_coverage

    output:
        file("${SM}.coverage.tsv") into SM_coverage
        file("${SM}.1mb.coverage.tsv") into SM_1mb_coverage
        file("${SM}.100kb.coverage.tsv") into SM_100kb_coverage


    """
        bam coverage ${SM}.bam > ${SM}.coverage.tsv
        bam coverage --window=1000000 ${SM}.bam > ${SM}.1mb.coverage.tsv
        bam coverage --window=100000 ${SM}.bam > ${SM}.100kb.coverage.tsv
    """
}


process coverage_SM_merge {

    publishDir "${params.out}/strain", mode: 'copy', overwrite: true

    input:
        val sm_set from SM_coverage.toSortedList()

    output:
        file("SM_coverage.full.tsv")
        file("SM_coverage.tsv") into SM_coverage_merged

    """
        echo -e 'bam\\tcontig\\tstart\\tend\\tproperty\\tvalue' > SM_coverage.full.tsv
        cat ${sm_set.join(" ")} >> SM_coverage.full.tsv

        # Generate condensed version
        cat <(echo -e 'strain\\tcoverage') <(cat SM_coverage.full.tsv | grep 'genome' | grep 'depth_of_coverage' | cut -f 1,6 | sort) > SM_coverage.tsv
    """
}

process coverage_bins_merge {

    publishDir "${params.out}/strain", mode: 'copy', overwrite: true

    input:
        val mb from SM_1mb_coverage.toSortedList()
        val kb_100 from SM_100kb_coverage.toSortedList()

    output:
        file("SM_coverage.mb.tsv.gz")

    """
        echo -e 'bam\\tcontig\\tstart\\tend\\tproperty\\tvalue' > SM_coverage.mb.tsv
        cat ${mb.join(" ")} >> SM_coverage.mb.tsv
        gzip SM_coverage.mb.tsv
    """
}


process call_variants_individual {

    cpus params.cores

    tag { SM }

    input:
        set val(SM), file("${SM}.bam"), file("${SM}.bam.bai") from merged_bams_individual

    output:
        file("${SM}.individual.sites.tsv") into individual_sites

    """
    # Perform individual-level calling
    contigs="`samtools view -H ${SM}.bam | grep -Po 'SN:([^\\W]+)' | cut -c 4-40`"
    echo \${contigs} | tr ' ' '\\n' | xargs --verbose -I {} -P ${task.cpus} sh -c "samtools mpileup --redo-BAQ -r {} --BCF --output-tags DP,AD,ADF,ADR,SP --fasta-ref ${reference_handle} ${SM}.bam | bcftools call --skip-variants indels --variants-only --multiallelic-caller -O z  -  > ${SM}.{}.individual.vcf.gz"
    order=`echo \${contigs} | tr ' ' '\\n' | awk '{ print "${SM}." \$1 ".individual.vcf.gz" }'`
    
    # Output variant sites
    bcftools concat \${order} -O v | vk geno het-polarization - | bcftools view -O z > ${SM}.individual.vcf.gz
    bcftools index ${SM}.individual.vcf.gz
    rm \${order}

    bcftools view -M 2 -m 2 -O v ${SM}.individual.vcf.gz | \\
    bcftools filter --include 'DP > 3' | \\
    egrep '(^#|1/1)' | \\
    bcftools query -f '%CHROM\\t%POS\\t%REF,%ALT\\n' > ${SM}.individual.sites.tsv
    """
}

/*
    Merge individual sites
*/


process merge_variant_list {

    publishDir "${params.out}/variation", mode: 'copy'

    input:
        val sites from individual_sites.toSortedList()

    output:
        file("sitelist.tsv.gz") into gz_sitelist
        file("sitelist.tsv.gz") into sitelist_stat
        file("sitelist.tsv.gz.tbi") into gz_sitelist_index


    """
        echo ${sites}
        cat ${sites.join(" ")} | sort -k1,1 -k2,2n | uniq > sitelist.tsv
        bgzip sitelist.tsv -c > sitelist.tsv.gz && tabix -s1 -b2 -e2 sitelist.tsv.gz
    """
}

union_vcf_set = merged_bams_union.combine(gz_sitelist).combine(gz_sitelist_index)

/* 
    Call variants using the merged site list
*/



process call_variants_union {

    cpus params.cores

    tag { SM }

    input:
        set val(SM), file("${SM}.bam"), file("${SM}.bam.bai"), file('sitelist.tsv.gz'), file('sitelist.tsv.gz.tbi') from union_vcf_set

    output:
        file("${SM}.union.vcf.gz") into union_vcf_to_list

    """
        contigs="`samtools view -H ${SM}.bam | grep -Po 'SN:([^\\W]+)' | cut -c 4-40`"
        echo \${contigs} | \\
        tr ' ' '\\n' | \\
        xargs --verbose -I {} -P ${task.cpus} sh -c "samtools mpileup --redo-BAQ -r {} --BCF --output-tags DP,AD,ADF,ADR,INFO/AD,SP --fasta-ref ${reference_handle} ${SM}.bam | bcftools call -T sitelist.tsv.gz --skip-variants indels --multiallelic-caller -O z  -  > ${SM}.{}.union.vcf.gz"
        order=`echo \${contigs} | tr ' ' '\\n' | awk '{ print "${SM}." \$1 ".union.vcf.gz" }'`

        # Output variant sites
        bcftools concat \${order} -O v | \\
        vk geno het-polarization - | \\
        bcftools filter -O u --threads ${task.cpus} --set-GTs . --include "QUAL >= ${qual} || FORMAT/GT == '0/0'" |  \\
        bcftools filter -O u --threads ${task.cpus} --set-GTs . --include "FORMAT/DP > ${min_depth}" | \\
        bcftools filter -O u --threads ${task.cpus} --set-GTs . --include "INFO/MQ > ${mq}" | \\
        bcftools filter -O u --threads ${task.cpus} --set-GTs . --include "(FORMAT/AD[*:1])/(FORMAT/DP) >= ${dv_dp} || FORMAT/GT == '0/0'" | \\
        bcftools view -O z > ${SM}.union.vcf.gz
        bcftools index ${SM}.union.vcf.gz
        rm \${order}
    """

}


process generate_union_vcf_list {

    cpus 1 

    publishDir "${params.out}/variation", mode: 'copy'

    input:
       val vcf_set from union_vcf_to_list.toSortedList()

    output:
       file("union_vcfs.txt") into union_vcfs

    """
        echo ${vcf_set.join(" ")} | tr ' ' '\\n' > union_vcfs.txt
    """
}

union_vcfs_in = union_vcfs.spread(contig_list)

process merge_union_vcf_chromosome {

    cpus params.cores

    tag { chrom }

    input:
        set file(union_vcfs:"union_vcfs.txt"), val(chrom) from union_vcfs_in

    output:
        val(chrom) into contigs_list_in
        file("${chrom}.merged.raw.vcf.gz") into raw_vcf

    """
        bcftools merge --regions ${chrom} -O z -m all --file-list ${union_vcfs} > ${chrom}.merged.raw.vcf.gz
        bcftools index ${chrom}.merged.raw.vcf.gz
    """
}


// Generate a list of ordered files.
contig_raw_vcf = contig_list*.concat(".merged.raw.vcf.gz")

process concatenate_union_vcf {

    cpus params.cores

    publishDir "${params.out}/variation", mode: 'copy'

    input:
        val merge_vcf from raw_vcf.toSortedList()

    output:
        set file("merged.raw.vcf.gz"), file("merged.raw.vcf.gz.csi") into raw_vcf_concatenated

    """
        bcftools concat --threads ${task.cpus} -O z ${merge_vcf.join(" ")}  > merged.raw.vcf.gz
        bcftools index --threads ${task.cpus} merged.raw.vcf.gz
    """
}

process filter_union_vcf {

    publishDir "${params.out}/variation", mode: 'copy'

    input:
        set file("merged.raw.vcf.gz"), file("merged.raw.vcf.gz.csi") from raw_vcf_concatenated

    output:
        set file("concordance.vcf.gz"), file("concordance.vcf.gz.csi") into filtered_vcf
        set file("concordance.vcf.gz"), file("concordance.vcf.gz.csi") into filtered_vcf_pairwise
        set file("concordance.vcf.gz"), file("concordance.vcf.gz.csi") into het_check_vcf
    """
        bcftools view merged.raw.vcf.gz | \\
        vk filter ALT --max=0.99 - | \\
        vk filter MISSING --max=0.05 - | \\
        vk filter REF --min=1 - | \\
        vk filter ALT --min=1 - | \\
        bcftools view -O z - > concordance.vcf.gz
        bcftools index concordance.vcf.gz
    """
}

filtered_vcf.into { filtered_vcf_gtcheck; filtered_vcf_stat; }


process calculate_gtcheck {

    publishDir "${params.out}/concordance", mode: 'copy'

    input:
        set file("concordance.vcf.gz"), file("concordance.vcf.gz.csi") from filtered_vcf_gtcheck

    output:
        file("gtcheck.tsv") into gtcheck
        file("gtcheck.tsv") into pairwise_compare_gtcheck

    """
        echo -e "discordance\\tsites\\tavg_min_depth\\ti\\tj" > gtcheck.tsv
        bcftools gtcheck -H -G 1 concordance.vcf.gz | egrep '^CN' | cut -f 2-6 >> gtcheck.tsv
    """

}


process stat_tsv {

    publishDir "${params.out}/vcf", mode: 'copy'

    input:
        set file("concordance.vcf.gz"), file("concordance.vcf.gz.csi") from filtered_vcf_stat

    output:
        file("concordance.stats") into filtered_stats

    """
        bcftools stats --verbose concordance.vcf.gz > concordance.stats
    """

}

/*
    Perform concordance analysis
*/

process process_concordance_results {

    publishDir "${params.out}/concordance", mode: "copy"

    input:
        file 'gtcheck.tsv' from gtcheck
        file 'filtered.stats.txt' from filtered_stats
        file 'SM_coverage.tsv' from SM_coverage_merged

    output:
        file("concordance.pdf")
        file("concordance.png")
        file("xconcordance.pdf")
        file("xconcordance.png")
        file("isotype_groups.tsv") into isotype_groups
        file("isotype_count.txt")
        file("WI_metadata.tsv")

    """
    # Run concordance analysis
    Rscript --vanilla `which process_concordance.R` ${params.debug}
    """

}

process generate_isotype_groups {

    executor 'local'

    input:
        file("isotype_groups.tsv") from isotype_groups

    output:
        file("pairwise_groups.txt") into pairwise_groups

    """
    cat isotype_groups.tsv | awk '{ curr_strain = \$2; curr_group = \$1; if (group_prev == curr_group) { print prev_strain "," curr_strain "\t" \$1 "\t" \$3 } ; prev_strain = \$2; group_prev = \$1; }' > pairwise_groups.txt
    """

}



process fq_concordance {

    cpus params.cores

    tag { SM }

    input:
        set val(SM), file("input.bam"), file("input.bam.bai") from fq_concordance_bam

    output:
        file('out.tsv') into fq_concordance_out

    """
        # Split bam file into individual read groups; Ignore MtDNA
        contigs="`samtools view -H input.bam | grep -Po 'SN:([^\\W]+)' | cut -c 4-40 | grep -v 'MtDNA' | tr ' ' '\\n'`"
        samtools split -f '%!.%.' input.bam
        # DO NOT INDEX ORIGINAL BAM; ELIMINATES CACHE!
        bam_list="`ls -1 *.bam | grep -v 'input.bam'`"

        ls -1 *.bam | grep -v 'input.bam' | xargs --verbose -I {} -P ${task.cpus} sh -c "samtools index {}"

        # Generate a site list for the set of fastqs
        rg_list="`samtools view -H input.bam | grep '^@RG.*ID:' | cut -f 2 | sed  's/ID://'`"
        # Perform individual-level calling
        for rg in \$rg_list; do
            echo \${contigs} | tr ' ' '\\n' | xargs --verbose -I {} -P ${task.cpus} sh -c "samtools mpileup --redo-BAQ -r {} --BCF --output-tags DP,AD,ADF,ADR,SP --fasta-ref ${reference_handle} \${rg}.bam | bcftools call --skip-variants indels --variants-only --multiallelic-caller -O v | bcftools query -f '%CHROM\\t%POS\\n' >> {}.\${rg}.site_list.tsv"
        done;
        cat *.site_list.tsv  | sort --temporary-directory=${params.tmpdir} -k1,1 -k2,2n | uniq > site_list.srt.tsv
        bgzip site_list.srt.tsv -c > site_list.srt.tsv.gz && tabix -s1 -b2 -e2 site_list.srt.tsv.gz
        
        # Call a union set of variants
        for rg in \$rg_list; do
            echo \${contigs} | tr ' ' '\\n' | xargs --verbose -I {} -P ${task.cpus} sh -c "samtools mpileup --redo-BAQ -r {} --BCF --output-tags DP,AD,ADF,ADR,SP --fasta-ref ${reference_handle} \${rg}.bam | bcftools call -T site_list.srt.tsv.gz --skip-variants indels --multiallelic-caller -O z > {}.\${rg}.vcf.gz"
            order=`echo \${contigs} | tr ' ' '\\n' | awk -v rg=\${rg} '{ print \$1 "." rg ".vcf.gz" }'`
            # Output variant sites
            bcftools concat \${order} -O v | \\
            vk geno het-polarization - | \\
            bcftools filter -O u --threads ${task.cpus} --set-GTs . --include "QUAL >= 10 || FORMAT/GT == '0/0'" |  \\
            bcftools filter -O u --threads ${task.cpus} --set-GTs . --include "FORMAT/DP > 3" | \\
            bcftools filter -O u --threads ${task.cpus} --set-GTs . --include "INFO/MQ > ${mq}" | \\
            bcftools filter -O u --threads ${task.cpus} --set-GTs . --include "(FORMAT/AD[*:1])/(FORMAT/DP) >= ${dv_dp} || FORMAT/GT == '0/0'" | \\
            bcftools query -f '%CHROM\\t%POS[\\t%GT\\t${SM}\\n]' | grep -v '0/1' | awk -v rg=\${rg} '{ print \$0 "\\t" rg }' > \${rg}.rg_gt.tsv
        done;
        cat *.rg_gt.tsv > rg_gt.tsv
        touch out.tsv
        Rscript --vanilla `which fq_concordance.R` 
    """
}

process combine_fq_concordance {

    publishDir "${params.out}/concordance", mode: 'copy', overwrite: true

    input:
        file("out*.tsv") from fq_concordance_out.toSortedList()

    output:
        file("fq_concordance.tsv")

    """
        cat <(echo 'a\tb\tconcordant_sites\ttotal_sites\tconcordance\tSM') out*.tsv > fq_concordance.tsv
    """


}

pairwise_groups_input = pairwise_groups.splitText( by:1 )

// Look for diverged regions among isotypes.
process pairwise_variant_compare {

    publishDir "${params.out}/concordance/pairwise", mode: 'copy', overwrite: true

    tag { pair }

    input:
        val(pair_group) from pairwise_groups_input
        set file("concordance.vcf.gz"), file("concordance.vcf.gz.csi") from filtered_vcf_pairwise

    output:
        file("${group}.${isotype}.${pair.replace(",","_")}.png")

    script:
        pair_group = pair_group.trim().split("\t")
        pair = pair_group[0]
        group = pair_group[1]
        isotype = pair_group[2]

    """
        bcftools query -f '%CHROM\t%POS[\t%GT]\n' -s ${pair} concordance.vcf.gz > out.tsv
        Rscript --vanilla `which plot_pairwise.R` 
        mv out.png ${group}.${isotype}.${pair.replace(",","_")}.png
        mv out.tsv ${group}.${isotype}.${pair.replace(",","_")}.tsv
    """

}

process heterozygosity_check {

    cpus params.cores

    publishDir "${params.out}/concordance", mode: "copy"

    input:
        set file("concordance.vcf.gz"), file("concordance.vcf.gz.csi") from het_check_vcf

    output:
        file("heterozygosity.tsv")

    """
        bcftools query -l concordance.vcf.gz | xargs --verbose -I {} -P ${task.cpus} sh -c "bcftools query -f '[%SAMPLE\t%GT\n]' --samples={} concordance.vcf.gz | grep '0/1' | uniq -c >> heterozygosity.tsv"
    """

}




workflow.onComplete {

    user="whoami".execute().text

    summary = """

    Pipeline execution summary
    ---------------------------
    Completed at: ${workflow.complete}
    Duration    : ${workflow.duration}
    Success     : ${workflow.success}
    workDir     : ${workflow.workDir}
    exit status : ${workflow.exitStatus}
    Error report: ${workflow.errorReport ?: '-'}
    Git info: $workflow.repository - $workflow.revision [$workflow.commitId]
    User: ${user}
    """

    println summary

    // mail summary
    ['mail', '-s', 'wi-nf', params.email].execute() << summary

    def outlog = new File("${params.out}/log.txt")
    outlog.newWriter().withWriter {
        outlog << summary
        outlog << "\n--------pyenv-------\n"
        outlog << "pyenv versions".execute().text
        outlog << "--------ENV--------"
        outlog << "ENV".execute().text
        outlog << "--------brew--------"
        outlog << "brew list".execute().text
        outlog << "--------R--------"
        outlog << "Rscript -e 'devtools::session_info()'".execute().text
    }

}

