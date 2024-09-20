#!/usr/bin/env perl

use strict;
use warnings;
use File::Basename;
use File::Temp qw/ tempfile /;
use Cwd qw/ abs_path /;
use IPC::Open3;
use Symbol qw( gensym );
use IO::Select;

# Improved function to escape special characters for regex
sub escape_for_regex {
    my ($string) = @_;
    $string =~ s/([\/\\\[\]^$.*+?(){}|])/\\$1/g;
    $string =~ s/\s+/\\s+/g;  # Replace whitespace with \s+
    $string =~ s/'/\\'/g;     # Escape single quotes
    return quotemeta($string);  # Use quotemeta for additional escaping
}

# Function to safely execute shell commands
sub safe_execute {
    my ($cmd) = @_;
    my ($in, $out, $err);
    $err = gensym;
    my $pid = open3($in, $out, $err, $cmd);
    
    my $sel = IO::Select->new;
    $sel->add($out, $err);
    
    my $stdout = '';
    my $stderr = '';
    
    while (my @ready = $sel->can_read) {
        foreach my $fh (@ready) {
            my $line = <$fh>;
            unless (defined $line) {
                $sel->remove($fh);
                next;
            }
            if ($fh == $out) {
                $stdout .= $line;
            } else {
                $stderr .= $line;
            }
        }
    }
    
    waitpid($pid, 0);
    my $exit_status = $? >> 8;
    
    return ($stdout, $exit_status, $stderr);
}

# Function to resolve params from environment or other sources
sub resolve_placeholders {
    my ($line) = @_;
    my $resolved_line = $line;

    # Resolve (( param "..." )) with environment variables or default values
    while ($resolved_line =~ /\(\(\s*param\s+"([^"]+)"\s+\)\)/) {
        my $param_name = $1;
        my $param_value = $ENV{$param_name} || "UNDEFINED_PARAM_$param_name";
        $resolved_line =~ s/\(\(\s*param\s+"$param_name"\s+\)\)/$param_value/g;
    }

    # Resolve (( grab <something> )) by looking it up from the merged YAML or other files
    while ($resolved_line =~ /\(\(\s*grab\s+([^\s]+)\s+\)\)/) {
        my $grab_target = $1;
        my ($grab_value, $exit_status, $error) = safe_execute("grep -oP '$grab_target:\\s*\\K.*' merged_temp.yml");
        $grab_value = "UNDEFINED_GRAB_$grab_target" if $exit_status != 0;
        chomp $grab_value;
        $resolved_line =~ s/\(\(\s*grab\s+$grab_target\s+\)\)/$grab_value/g;
    }

    # Resolve (( concat ... )) by concatenating the values
    while ($resolved_line =~ /\(\(\s*concat\s+(.*?)\s+\)\)/) {
        my $concat_targets = $1;
        my $concat_values = "";
        for my $target (split /\s+/, $concat_targets) {
            my ($value, $exit_status, $error) = safe_execute("grep -oP '$target:\\s*\\K.*' merged_temp.yml");
            $value = $target if $exit_status != 0;
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

            if ($content =~ /^\Q$key\E:/) {
                $found_key = 1;
                $current_indent = $indent_level;
                $found_line = $line_number;
            } elsif ($found_key && $content =~ /\Q$value\E/) {
                close $fh;
                return $found_line;
            }
        }
    }
    close $fh;
    return $found_line;
}

# Updated function to merge YAML files using Spruce and track blame with hierarchical approach
sub spruce_merge_with_blame {
    my ($output_file, @files) = @_;

    my ($temp_merged_fh, $temp_merged) = tempfile();

    print "Performing Spruce merge...\n";
    my ($spruce_output, $spruce_exit, $spruce_error) = safe_execute("spruce merge @files");
    die "Spruce merge failed: $spruce_error" if $spruce_exit != 0;
    print $temp_merged_fh $spruce_output;
    close $temp_merged_fh;

    print "Resolving placeholders and adding blame...\n";
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
                $value =~ s/^\s+|\s+$//g;  # Trim whitespace
                my $escaped_key = escape_for_regex($key);
                my $escaped_value = escape_for_regex($value);
                my $found = 0;
                for my $file (@files) {
                    my $grep_command = qq(grep -nP '^\\s*$escaped_key:\\s*$escaped_value' "$file");
                    my ($grep_result, $grep_exit, $grep_error) = safe_execute($grep_command);
                    if ($grep_exit == 0) {
                        chomp $grep_result;
                        my ($line_number) = split /:/, $grep_result;
                        print $out_fh "${indent}# File: $file (Line: $line_number)\n";
                        print $out_fh "$resolved_line\n";
                        $found = 1;
                        last;
                    }
                }
                if (!$found) {
                    print $out_fh "$resolved_line\n";
                    warn "Warning: Key-value pair '$key: $value' not found in any file\n";
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

    print "Final merged file with blame:\n";
    system("cat $output_file");

    unlink $temp_merged;
}

# Main script
sub main {
    my $base_dir = dirname(abs_path($0));
    chdir $base_dir or die "Cannot change to directory '$base_dir': $!";

    # Prepare input files
    my @input_files = (
        'pipeline/base.yml',
        glob('pipeline/*/*.yml'),
        'settings.yml'
    );
    @input_files = grep { !/pipeline\/custom.*\/.*\.yml/ && !/pipeline\/optional.*\/.*\.yml/ } @input_files;

    if (@ARGV < 1) {
        die "Usage: $0 <output_merged.yml>\n";
    }

    my $merged_file = $ARGV[0];

    print "Merging input files using Spruce and tracking blame...\n";
    spruce_merge_with_blame($merged_file, @input_files);

    print "Merged file with blame information has been saved to: $merged_file\n";
}

main();
