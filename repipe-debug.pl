#!/usr/bin/env perl

use strict;
use warnings;
use File::Basename;
use File::Temp qw/ tempfile /;
use Cwd qw/ abs_path /;

# spruce-merge-diff-file-blame
#
# Script for merging YAML files using Spruce, resolving dynamic placeholders,
# and tracking file-level blame based on YAML hierarchy.

# Function to escape special characters for grep
sub escape_for_grep {
    my ($str) = @_;
    $str =~ s/([\[\]^$.*()+?{}\|\\])/\\$1/g;
    return $str;
}

# Function to resolve params from environment or other sources
sub resolve_placeholders {
    my ($line) = @_;
    my $resolved_line = $line;

    # Resolve (( param "..." )) with environment variables or default values
    if ($line =~ /\(\(.*param\s+"(.*)"\s+\)\)/) {
        my $param_name = $1;
        my $param_value = exists $ENV{$param_name} ? $ENV{$param_name} : "UNDEFINED_PARAM_$param_name";
        $resolved_line =~ s/\(\(\s*param\s+"$param_name"\s+\)\)/$param_value/g;
    }

    # Resolve (( grab <something> )) by looking it up from the merged YAML or other files
    if ($line =~ /\(\(.*grab\s+(.*)\s+\)\)/) {
        my $grab_target = $1;
        my $grab_value = `grep -oP '$grab_target:\\s*\\K.*' merged_temp.yml 2>/dev/null` || "UNDEFINED_GRAB_$grab_target";
        chomp $grab_value;
        $resolved_line =~ s/\(\(\s*grab\s+$grab_target\s+\)\)/$grab_value/g;
    }

    # Resolve (( concat ... )) by concatenating the values
    if ($line =~ /\(\(.*concat\s+(.*)\s+\)\)/) {
        my $concat_targets = $1;
        my $concat_values = "";
        for my $target (split /\s+/, $concat_targets) {
            my $value = `grep -oP '$target:\\s*\\K.*' merged_temp.yml 2>/dev/null` || $target;
            chomp $value;
            $concat_values .= $value;
        }
        $resolved_line =~ s/\(\(\s*concat\s+$concat_targets\s+\)\)/$concat_values/g;
    }

    return $resolved_line;
}

# Function to find the correct line number based on YAML hierarchy
sub find_hierarchical_line_number {
    my ($file, $key, $value) = @_;
    my $current_indent = 0;
    my $line_number = 0;
    my $found_key = 0;
    my $found_line = "";

    open my $fh, '<', $file or die "Cannot open file '$file': $!";
    while (my $line = <$fh>) {
        $line_number++;
        if ($line =~ /^(\s*)(.+)$/) {
            my $indent_level = length($1);
            my $content = $2;

            if ($indent_level <= $current_indent) {
                $found_key = 0;
            }

            if ($content =~ /^$key:/) {
                $found_key = 1;
                $current_indent = $indent_level;
                $found_line = $line_number;
            } elsif ($found_key && $content =~ /$value/) {
                close $fh;
                return $found_line;
            }
        }
    }
    close $fh;
    return $found_line;
}

# Function to merge YAML files using Spruce and track blame with hierarchical approach
sub spruce_merge_with_blame {
    my ($output_file, @files) = @_;

    my ($temp_merged_fh, $temp_merged) = tempfile();

    print "Performing Spruce merge...\n";
    system("spruce merge @files > $temp_merged");

    print "Resolving placeholders...\n";
    open my $out_fh, '>', $output_file or die "Cannot open file '$output_file': $!";
    print $out_fh "# Debug: Input files: @files\n";

    open my $in_fh, '<', $temp_merged or die "Cannot open file '$temp_merged': $!";
    while (my $line = <$in_fh>) {
        chomp $line;
        # Skip comments and empty lines
        if ($line =~ /^#/ || $line =~ /^\s*$/) {
            print $out_fh "$line\n";
            next;
        }

        # Resolve any placeholders in the line
        my $resolved_line = resolve_placeholders($line);

        # Determine blame by checking each input file for the resolved value
        if ($resolved_line =~ /^(\s*)(.+)$/) {
            my $indent = $1;
            my $content = $2;
            if ($content =~ /^([a-zA-Z0-9_]+):(.*)$/) {
                my $key = $1;
                my $value = $2;
                my $found = 0;
                for my $file (@files) {
                    open my $file_fh, '<', $file or die "Cannot open file '$file': $!";
                    while (my $file_line = <$file_fh>) {
                        if ($file_line =~ /^\s*\Q$key\E:\s*\Q$value\E/) {
                            my $line_number = find_hierarchical_line_number($file, $key, $value);
                            if ($line_number) {
                                print $out_fh "${indent}# File: $file (Line: $line_number)\n";
                                print $out_fh "$resolved_line\n";
                                $found = 1;
                                last;
                            }
                        }
                    }
                    close $file_fh;
                    last if $found;
                }
                if (!$found) {
                    print $out_fh "$resolved_line\n";
                    warn "Warning: Key-value pair '$key:$value' not found in any file\n";
                }
            } else {
                print $out_fh "$resolved_line\n";
            }
        } else {
            print $out_fh "$resolved_line\n";
        }
    }
    close $in_fh;
    close $out_fh;

    unlink $temp_merged;

    print "Final merged file with blame:\n";
    system("cat $output_file");
}

# Main script
sub main {
    my $base_dir = dirname(abs_path($0));
    chdir $base_dir or die "Cannot change directory to $base_dir: $!";

    # Prepare input files
    my @input_files = grep { !/pipeline\/custom.*\/.*\.yml/ && !/pipeline\/optional.*\/.*\.yml/ } 
                      glob("pipeline/base.yml pipeline/*/*.yml settings.yml");

    if (@ARGV < 1) {
        die "Usage: $0 <output_merged.yml>\n";
    }

    my $merged_file = $ARGV[0];

    print "Merging input files using Spruce and tracking blame...\n";
    spruce_merge_with_blame($merged_file, @input_files);

    print "Merged file with blame information has been saved to: $merged_file\n";
}

main();
