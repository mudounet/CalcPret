package ClearcaseMgt;

use strict;
use warnings;
use Log::Log4perl qw(:easy);
use File::Basename;
use Win32::OLE;
use Data::Dumper;
use Cwd qw(cwd abs_path);
Win32::OLE->Option(Warn => 3);

use vars qw($VERSION @EXPORT_OK @ISA @EXPORT);
require Exporter;
@ISA       = qw(Exporter);
@EXPORT    = qw();
@EXPORT_OK = qw(getComment addToSource findVersions getDirectoryStructure getBranchListVOB getLabelListVOB getLabelListElement setLabel checkoutElement isSnapshotView getViewNameByElement isLatest renameElement getAttributes getAttribute getConfigSpec setConfigSpec setAttribute isCheckedoutElement isPrivateElement uncheckoutElement checkinElement moveElement unlockFile lockFile doCleartool);


$VERSION = sprintf('%d.%02d', (q$Revision: 1.15 $ =~ /\d+/g));

my $cc = Win32::OLE->new('ClearCase.Application');
my $ct = Win32::OLE->new('ClearCase.ClearTool');


sub getComment {
	my ($element, $version) = @_;

	my $versionedElement = _getVersionedElement($element, $version) or return undef;
	return $versionedElement->Comment;
}

sub addToSource {
	my $element = shift;
	my $comment = shift;
	
	LOGDIE "It is mandatory to add a comment." unless $comment;
	LOGDIE "Element \"$element\" is not readable" unless -r $element;
	
	my $checkedOutElement;
	#=# / mkelem -eltype directory / do not work in command line to add a directory to source control #=#
	if (-d $element) {
	    my $CommandResponse;
		$CommandResponse = doCleartool("mkelem -c \"$comment\" -mkpath \"$element\" ");
		ERROR "Error while trying to add directory : \"$element\"" unless $CommandResponse;
		return undef unless $CommandResponse;
		$checkedOutElement = _getVersionedElement($element) or return undef;
		return $checkedOutElement;
	} else {
		eval { $checkedOutElement = $cc->CreateElement($element, $comment); };
		if ($@) { 
			ERROR "Error while trying to add element: $@"; 
			return undef;
		}
	}
	return $checkedOutElement;
}

sub checkinElement {
	my $element = shift;
	my $comment = shift;
	my $forceCheckin = shift;
	
	$forceCheckin = 0 unless $forceCheckin;
	LOGDIE "It is mandatory to add a comment." unless $comment;
	$element = _removeLastSlashFromDirectory($element) if -d $element;
	my $versionedElement = _getVersionedElement($element) or return undef;
	eval { $versionedElement->Element->CheckedOutFile->CheckIn($comment, $forceCheckin, undef, 1); };
	if($@){ 
		ERROR "Error while performing checkinElement: $@"; 
		return undef;
	}
	return not isCheckedoutElement($element);
}

sub uncheckoutElement {
	my $element = shift;
	$element = _removeLastSlashFromDirectory($element) if -d $element;
	my $versionedElement = _getVersionedElement($element) or return undef;
	eval { $versionedElement->Element->CheckedOutFile->UnCheckout(1); };
	if($@){ 
		ERROR "Error while performing uncheckoutElement: $@"; 
		return undef;
	}
	return not isCheckedoutElement($element);
}

sub checkoutElement {
	my $element = shift;
	my $comment = shift;
	
	my $versionedElement = _getVersionedElement($element) or return undef;
	eval { $versionedElement->Checkout(0, $comment); };
	if($@){ 
		ERROR "Error while performing checkoutElement: $@"; 
		return undef;
	}
	return isCheckedoutElement($element);
}

sub setAttribute {
	my $element = shift;
	my $attribute = shift;
	my $newValue = shift;
	my $version = shift;

	# Removing old attribute
	my $versionedElement = _getVersionedElement($element, $version) or return undef;
	my $VOB = $versionedElement->VOB or LOGDIE("Could not get versioned element : ".Win32::OLE->LastError());
	my $attributeType = $VOB->AttributeType($attribute) or LOGDIE("Could not get versioned element : ".Win32::OLE->LastError());;

	# Adding / modifying new attribute with desired value
	$attributeType->Apply($versionedElement, $newValue, "Applied automatically using CAL", 1);
	
	# Checking if result is correct
	my $result = getAttribute($element, $attribute, $version);
	return ("$result" eq "$newValue");
}

sub getAttribute {
	my $element = shift;
	my $attribute = shift;
	my $version = shift;
	
	return undef unless isAttributeDefined($element, $attribute, $version);
	
	my $versionedElement = _getVersionedElement($element, $version) or return undef;
	my $value = $versionedElement->Attribute($attribute)->Value;
	DEBUG "Attribute \"$attribute\" has been found with value \"$value\"" and return $value;
}

sub getLabelListVOB {
	my $element = shift;
	
	my $VOB = _getVOB($element) or return 0;
	my $labelTypes = $VOB->LabelTypes;
	
	my $curItemIndex = 1;
	my @list;
	while($curItemIndex <= $labelTypes->Count) {
		push @list, $labelTypes->Item($curItemIndex++)->Name;
	}
	return \@list;
}

sub getBranchListVOB {
	my $element = shift;
	
	my $VOB = _getVOB($element) or return 0;
	my $branchTypes = $VOB->BranchTypes;
	
	my $curItemIndex = 1;
	my @list;
	while($curItemIndex <= $branchTypes->Count) {
		push @list, $branchTypes->Item($curItemIndex++)->Name;
	}
	return \@list;
}

sub getLabelListElement {
	my ($element, $version) = @_;
	
	my $versionedElement  = _getVersionedElement($element, $version) or return 0;
	my $labels = $versionedElement->Labels;
	my $curItemIndex = 1;
	my @list;
	while($curItemIndex <= $labels->Count) {
		push @list, $labels->Item($curItemIndex++)->Type->Name;
	}
	return \@list;
}

sub setLabel {
	my ($element, $label, $version, $moveLabel, $recursivelabel, $comment) = @_;
	
	my $VOB = _getVOB($element) or return 0;
	my $labelType = $VOB->LabelType($label);
	my $versionedElement  = _getVersionedElement($element, $version) or return 0;

	$labelType->Apply($versionedElement, $comment, $moveLabel, $recursivelabel);
	return isLabelDefined($element, $label, $version);
}

sub isLabelDefined {
	my ($element, $label, $version) = @_;
	my @list = @{getLabelListElement($element, $version)};
	return scalar grep(/^\s*$label\s*$/, @list);
}

sub isAttributeDefined {
	my $element = shift;
	my $attribute = shift;
	my $version = shift;

	_getVersionedElement($element, $version) or return undef;
	return 1 if scalar(grep(/^$attribute$/, getAttributes($element, $version)));
	DEBUG "No attribute called \"$attribute\" has been found" and return 0;
}

sub isLatest {
	my $element = shift;
	
	my $versionedElement = _getVersionedElement($element) or return undef;
	
	return $versionedElement->IsLatest;
}

sub getAttributes {
	my $element = shift;
	my $version = shift;

	my $versionedElement = _getVersionedElement($element, $version) or return undef;
	
	my $attributes = $versionedElement->Attributes;
	my $curItemIndex = 1;
	my @list;
	while($curItemIndex <= $attributes->Count) {
		push @list, $attributes->Item($curItemIndex++)->Type->Name;
	}
	return @list;
}

sub moveElement {
	my $oldelement = shift;
	my $newElement = shift;
	
	LOGDIE "Not implemented";
	#DEBUG doCommand("cleartool move \"$oldelement\" \"$newElement\"");
}

sub renameElement {
	my $element = shift;
	my $newName = shift;
	my $comment = shift;
	
	my $ccElement = _getElement($element) or return undef;
	my $result;
	
	DEBUG "Element to rename : $element";
	ERROR "renaming doesn't work if parent directory is checked out" and return 0 if $ccElement->Parent->Version->IsCheckedOut;
	my $checkoutDir = $ccElement->Parent->Version->CheckOut(0, "Renaming of a document");
	eval { $ccElement->Rename($newName, $comment); };
	if($@){ 
		ERROR "Error while performing renameElement: $@"; 
		$checkoutDir->UnCheckOut(1);
		return 0;
	}
	else {
		$checkoutDir->CheckIn;
		return 1;
	}
}

sub unlockFile {
	my $file = shift;
	my $comment = shift;
	LOGDIE "Not implemented";
	#DEBUG doCommand("cleartool unlock -c \"$comment\" \"$file\"");
}

sub lockFile {
	my $file = shift;
	my $user = shift;
	my $comment = shift;

	LOGDIE "Not implemented";
	#DEBUG doCommand("cleartool unlock -c \"$comment\" -nuser \"$user\" \"$file\"", 0, 1);
}

sub isCheckedoutElement {
	my $element = shift;
	my $version = shift;

	my $versionedElement = _getVersionedElement($element, $version) or return undef;
	
	return $versionedElement->IsCheckedOut();
}

sub getConfigSpec {
	my $desiredView = shift;
	my $configSpec;
	
	my $view = _getView($desiredView) or return undef;
	
	eval { $configSpec = $view->ConfigSpec; };
	if($@){ 
		DEBUG "An error occured while getting config-spec: $@"; 
		return undef;
	}
	return $configSpec;
}

sub setConfigSpec {
	my $configSpecFilename = shift;
	my $desiredViewPath = shift;
	
	my $viewName = getViewNameByElement($desiredViewPath);
	if (isSnapshotView($viewName)) {
		my $oldDir = cwd();
		$configSpecFilename = abs_path($configSpecFilename);
		chdir($desiredViewPath);
		my $result = doCommand("cleartool setcs \"$configSpecFilename\"", undef, 1);
		chdir($oldDir);
		return $result;
	}
	else {
		my $result = doCommand("cleartool setcs -tag \"$viewName\" \"$configSpecFilename\"", undef, 1);
	}
}

sub isSnapshotView {
	my $viewName = shift;
	my $view = _getView($viewName) or return undef;
	my $result ;
	eval { $result = $view->IsSnapShot; };
	if($@){ 
		DEBUG "Tryed to see if \"$viewName\" was a snapshot view";
		ERROR "Error while retrieving type of view: $@"; 
		return undef;
	}
	return $result;
}

sub getViewNameByElement {
	my $element = shift;
	my $view;
	
	$element = _getElement($element) or return undef;
	eval { $view = $element->View(); $view = $view->TagName if $view; };
	if($@){ 
		DEBUG "Retrieving name of view using path \"$element\"";
		ERROR "Error while retrieving name: $@"; 
		return undef;
	}
	else {
		return $view;
	}
}

sub _getElement {
	my $element = shift;

	$element = _removeLastSlashFromDirectory($element) if -d $element;

	my $ccElement;
	eval { $ccElement = $cc->Element($element); };
	if($@){ 
		DEBUG "Retrieving Element called \"$element\"";
		DEBUG "Element doesn't exists: $@"; 
		return undef;
	}
	return $ccElement;
}

sub _getCheckedOutElement {
	my $element = shift;

	$element = _removeLastSlashFromDirectory($element) if -d $element;
	DEBUG "Retrieving Checked-out element called \"$element\"";
	my $checkedOutElement;
	eval { $checkedOutElement = $cc->CheckedOutFile($element); };
	if($@){ 
		DEBUG "Checked-out doesn't exists: $@"; 
		return undef;
	}
	return $checkedOutElement;
}

sub _getView {
	my ($viewName) = @_;
	my $view;
	
	if($viewName) {
		DEBUG "Retrieving View called \"$viewName\"";
		eval { $view = $cc->View($viewName); };
	}
	else {
		DEBUG "Retrieving current view";
		eval { $view = $cc->View(); };
	}
	
	if($@){ 
		ERROR "View retrieval made an error: $@"; 
		return undef;
	}
	return $view;
}

sub _getVOB {
	my $element = shift;

	my $versionedElement = _getVersionedElement($element) or return undef;
	
	my $VOB;
	eval { $VOB = $versionedElement->VOB; };
	if($@){ 
		DEBUG "Retrieving VOB based in element \"$element\"";
		DEBUG "VOB retrieval failed: $@"; 
		return undef;
	}
	
	return $VOB;
}

sub getDirectoryStructure {
	my ($directory, %params) = @_;
	
	my $filter = 'version(/main/LATEST)';
	if($params{-label}) {
		$filter = "lbtype(".$params{-label}.")";
	}
	
	return undef unless -d $directory;
	return findVersions($directory, $filter);
}

sub findVersions {
	my ($element, $filter, %args) = @_;
	
	DEBUG "Performing find operation on \"$element\" with filter \"filter\"";
	my $list = doCommand("cleartool find \"$element\" -version \"$filter\" -print", undef, 1);

	my %list;
	foreach my $file (split(/\n/, $list)) {
		if($file =~ /^(.*)@@[\\\/]([^\\\/]+)[\\\/](\d+)$/) {
			push(@{$list{$1}{$2}}, $3);
		}
		else {
			ERROR "Unknown answer \"$file\"";
		}
	}
	
	if($args{'-LatestOnly'}) {
		foreach my $file (keys %list) {
			foreach my $branch (keys %{$list{$file}}) {
				my @array = sort { $b <=> $a } @{$list{$file}{$branch}};
				my $latest = shift @array;
				$list{$file}{$branch} = $latest;
				$list{$file} = $latest if $args{'-Branch'} and $args{'-Branch'} eq $branch;
			}
		}
	}
	
	return \%list;
}

sub _getVersionedElement {
	my ($extendedPath,$version, $no_messages) = @_;
	
	$extendedPath = _removeLastSlashFromDirectory($extendedPath) if -d $extendedPath;
	
	$extendedPath = $extendedPath.'@@'.$version if $version;
	
	my $versionedElement;
	eval { $versionedElement = $cc->Version($extendedPath); };
	if($@){ 
		DEBUG "Retrieving Version called \"$extendedPath\"" unless $no_messages;
		DEBUG "Version doesn't exists: $@" unless $no_messages; 
		return undef;
	}
	return $versionedElement;
}

sub isPrivateElement {
	my $element = shift;

	return 1 unless defined _getVersionedElement($element, undef, 'NO_MESSAGE');
	return 0;
}


sub doCleartool {
	my $command = shift;
	
    my $CommandResponse;
	DEBUG "Command: $command";
	eval { $CommandResponse = $ct->CmdExec($command); };
	if ($@) { 
		ERROR "Error while trying to execute command:\n$command\n Returning: $@";
		ERROR "Responding: $CommandResponse";
		return undef;
	}
	DEBUG "Responding: $CommandResponse";
	return $CommandResponse;
}

sub doCommand {
	my $command = shift;
	my $skipRecording = shift;
	my $authorizeExec = shift;

	LOGDIE "Forbidden to use this function" unless $authorizeExec;
	DEBUG "Command entered : >>>$command<<<" unless $skipRecording;
	my $result = `$command 2>&1`;

	WARN "This command has to be updated using cleartool";
	
	my $returnString = 'UNKNOWN';
	my $message = '';
	if ($result =~ /^cleartool: Error:\s*(.*)/) {
		$message = $1;
		$returnString = "ERROR";
	} elsif ($result =~ /^cleartool: Warning:\s*(.*)/) {
		$message = $1;
		$returnString = "WARNING";
	} else {
		$returnString = "OK";
	}
	
	if($returnString ne 'OK') {
		WARN "Command entered was : >>>$command<<<";
		if($returnString eq 'WARNING') {
			WARN "Warning returned by command: $message";
		} elsif ($returnString eq 'ERROR') {
			ERROR "Error returned by command: $message";
		} else {
			ERROR "Unknown event : >>>$result<<<";
		}
	}
	else 
	{
		return $result;
	}
	return $returnString;
}

sub _removeLastSlashFromDirectory {
	my $directory = shift;
	$directory =~ s/(\/*|\\*)$//;
	return $directory;
}

1;