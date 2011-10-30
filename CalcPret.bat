@rem = ' PERL for Windows NT - ccperl must be in search path
@echo off
ccperl %0 %1 %2 %3 %4 %5 %6 %7 %8 %9
goto endofperl
@rem ';

BEGIN {
	$0=~/^(.+[\\\/])[^\\\/]+[\\\/]*$/;
	my $physicalDir= $1 || "./";
	chdir($physicalDir);
}
use lib qw(lib);
use strict;
use warnings;
use Common;
use File::Copy;
use Data::Dumper;

use Storable qw(store retrieve thaw freeze);
use HTML::Template;
use XML::Simple;

use constant {
	PROGRAM_VERSION => '0.1',
	TEMPLATE_ROOT_DIR => 'Templates',
	INPUT_DIR => 'inputs',
	OUTPUT_DIR => 'outputs',
	DEFAULT_TEMPLATE_DIR => '.',
	DEFAULT_TEMPLATE => 'Xml',
	MAIN_TEMPLATE_NAME => 'main.tmpl',
};

INFO("Starting program (V ".PROGRAM_VERSION.")");

#########################################################
# loading of Configuration files
#########################################################
my $config = loadLocalConfig("ApplyTemplateToCSV.config.xml", 'config.xml', KeyAttr => {}, ForceArray => qr/^(component|rule)$/);

#########################################################
# Using template files
#########################################################
my $SCRIPT_DIRECTORY = getScriptDirectory();
my $rootTemplateDirectory = "./";

my $userTemplateDir = $SCRIPT_DIRECTORY.TEMPLATE_ROOT_DIR;

createDirInput($userTemplateDir, 'Templates files for current user has to be put in this directory');
createDirInput($SCRIPT_DIRECTORY.INPUT_DIR, 'Place all inputs XML documents in this folder');
createDirInput($SCRIPT_DIRECTORY.OUTPUT_DIR, 'All output files are put in this folder');

#########################################################
# Foreach component to generate
#########################################################
foreach my $component (@{$config->{components}->{component}}) {
	INFO "Processing Component \"$component->{name}\"";
	
	my %modulesDescriptors;
	
	my $file = $SCRIPT_DIRECTORY.INPUT_DIR.'/'.$component->{refFile};
	
	#########################################################
	# Reading connections variables
	#########################################################
	unless (open IN_FILE, $file) {
		ERROR "input file \"$file\" cannot be processed. Component is skipped.";
		next;
	}
	
	my %variablesList;
	my @tab;
	my $lineNumber = 0;
	
	my $headerRaw = <IN_FILE>;
	chomp($headerRaw);
	my @header = split(/;/, $headerRaw);
	
	my $offset = 0;
	foreach my $column (@header) {
		$offset++;
		next unless $column =~ /^\s*$/;
		WARN "Column $offset is not named. it will be ignored";	
	}
	
	my %flatGroupsList;
	
	# Creating list of list, in an flat manner
	foreach my $line (<IN_FILE>) {
		chomp($line);
		
		my @line = split(/;/, $line);
		
		my %line;
		
		my $offset = 0;
		foreach my $column (@header) {
			$offset++;
			next if $column =~ /^\s*$/;
			$line{$column} = $line[$offset - 1];
		}
		
		my $pathRaw = $line{"PATH"} or LOGDIE("Column \"PATH\" (case-sensitive) is not defined, and it is mandatory.");
		
		foreach my $path (split(/\s*,\s*/, $pathRaw)) {
			push(@{$flatGroupsList{$path}}, \%line);
		}
	}
	
	close IN_FILE;
	
	INFO "Creating list of list, in an imbricated manner";
	my %imbricatedList;
	foreach my $flatPath (keys %flatGroupsList) {
		DEBUG "Processing group \"$flatPath\"";
		my @groups = split(/\./, $flatPath);
		
		my $results = createGroup(\@groups, $flatGroupsList{$flatPath});
		$imbricatedList{$flatPath} = $results;
	}	
	
	INFO "Merging lists, because they are eventually duplicate keys";
	my $mergedList;
	foreach my $flatPath (keys %imbricatedList) {
		$mergedList = merge_hashes_normal ($mergedList, $imbricatedList{$flatPath});
	}
	
	INFO "Generating Final array";
	my $finalList = make_arrays($mergedList);
	
	#########################################################
	# This part generates input / output files
	#########################################################
	my $outDir = $SCRIPT_DIRECTORY.OUTPUT_DIR.'/';
	
	open OUTFILE, ">$outDir/$component->{outFile}";
	
	my $template_file = $SCRIPT_DIRECTORY.INPUT_DIR.'/'.$component->{templateFile};
	my $mainTemplate = HTML::Template -> new( die_on_bad_params => 0, filename => $template_file );
	
	foreach my $key (keys %$mergedList) {
		$mainTemplate->param($key => $mergedList->{$key} );
	}
	
	INFO "Generating \"$component->{outFile}\"";
	print OUTFILE $mainTemplate->output;
	close OUTFILE;


	exit;
}
	
sub createGroup {
	my ($keyList, $list) = @_;
	
	
	my @localKeyList = @$keyList;
	my $currentKeyField = shift @localKeyList;
	
	LOGDIE "ERRREURRRR" unless $currentKeyField;
	
	my %table;
	foreach my $item (@$list) {
		my $keyValue = $currentKeyField;
		
		$keyValue = $currentKeyField.":".$item->{$currentKeyField} if defined ($item->{$currentKeyField});
		
		push(@{$table{$keyValue}}, $item);
	}
	
	if(scalar (@localKeyList) > 0) {
		foreach my $keyValue (keys %table) {
			$table{$keyValue} = createGroup(\@localKeyList, $table{$keyValue});
		}
	}
	
	return \%table;
}

sub merge_hashes_normal {
    my ($x, $y) = @_;

    foreach my $k (keys %$y) {

		if (!defined($x->{$k})) {
				$x->{$k} = $y->{$k};
			} else {
				$x->{$k} = merge_hashes_normal($x->{$k}, $y->{$k});
			}
    }
    return $x;
}

sub make_arrays {
    my ($x) = @_;

    foreach my $key (keys %$x) {

		if($key =~ /(.*):(.*)/) {
			my $realKey = $1;
			my $value = $2;
			my $hash = $x->{$key};
			$hash->{$realKey} = $value;
			
			push(@{$x->{$realKey}}, $hash);
			delete $x->{$key};
		}
		else {
			$x->{$key} = $x->{$key};
		}
    }
    return $x;
}

sub loadModule {
	my ($module_name) = @_;

	my $file = $SCRIPT_DIRECTORY.INPUT_DIR.'/model_'.$module_name.'.descr.xml';
	unless (-r $file) {
		ERROR("FileName of module \"$module_name\" has not been found on path \"$file\"");
		return;
	}
	my $component = XMLin($file, KeyAttr => {}, ForceArray => qr/^(pin)$/);
	
	return $component;
}

sub createDirInput {
	my ($folder, $readme_message) = @_;
	if (not -d $folder) {
		mkdir($folder);
		INFO("Creating commented directory ".$folder);
		open FILE,">".$folder."/readme.txt";
		printf FILE $readme_message;
		close FILE;
	}
}

__END__
:endofperl
pause