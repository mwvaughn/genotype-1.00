/^#/    {
    print $0 > "snv.vcf";
    print $0 > "indels.vcf";
    next;
    }

/^[^\t]+\t[0-9]+\t[^\t]*\t[atgcATGC]\t[a-zA-Z]\t/   {
    print $0 > "snv.vcf";
    next;
    }

    {
    print $0 > "indels.vcf";
    next;
    }