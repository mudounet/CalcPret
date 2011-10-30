package ClearquestMgt;

use strict;
use warnings;
use Log::Log4perl qw(:easy);
use CQPerlExt; 
use Data::Dumper;

use vars qw($VERSION @EXPORT_OK @ISA @EXPORT);
require Exporter;
@ISA       = qw(Exporter);
@EXPORT    = qw();
@EXPORT_OK = qw(sortQuery connectCQ cancelAction editEntity makeQuery disconnectCQ getEntity getDuplicatesAsString getAvailableActions getEntityFields getChilds getFieldsRequiredness changeFields makeChanges);
$VERSION = sprintf('%d.%02d', (q$Revision: 1.15 $ =~ /\d+/g));

my $session;

use constant {
	MANDATORY => 1,
	OPTIONAL => 2,
	READONLY => 3,
	USE_HOOK => 4,
	BOOL_OP_AND => 1,
	BOOL_OP_OR => 2,
};

use constant {
	COMP_OP_EQ => 1, # Equality operator (=)
	COMP_OP_NEQ => 2, # Inequality operator (<>)
	COMP_OP_LT => 3, # Less-than operator (<)
	COMP_OP_LTE => 4, # Less-than or Equal operator (<=)
	COMP_OP_GT => 5, # Greater-than operator (>)
	COMP_OP_GTE => 6, # Greater-than or Equal operator (>=)
	COMP_OP_LIKE => 7, # Like operator (value is a substring of the string in the given field)
	COMP_OP_NOT_LIKE => 8, # Not-like operator (value is not a substring of the string in the given field)
	COMP_OP_BETWEEN => 9, # Between operator (value is between the specified delimiter values)
	COMP_OP_NOT_BETWEEN => 10, # Not-between operator (value is not between specified delimiter values)
	COMP_OP_IS_NULL => 11, # Is-NULL operator (field does not contain a value)
	COMP_OP_IS_NOT_NULL => 12, # Is-not-NULL operator (field contains a value)
	COMP_OP_IN => 13, # In operator (value is in the specified set)
	COMP_OP_NOT_IN => 14, # Not-in operator (value is not in the specified set)
};

sub connectCQ {
	my ($login, $password, $database) = @_;
	
	LOGDIE "Login is not specified" unless $login and not ref($login);
	LOGDIE "Password is not specified" unless $password and not ref($password);
	LOGDIE "Database is not specified" unless $database or ref($database);
	
	$session = CQSession::Build(); 
	
	eval( '$session->UserLogon ($login, $password, $database, "")' );
	if($@) {
		my $error_msg = $@;
		DEBUG "Error message is : $error_msg";
		ERROR "Clearquest database is not reachable actually. Check network settings. It can be considered as normal if you are not currently connected to the Alstom intranet" and return 0 if($error_msg =~ /Unable to logon to the ORACLE database/);
		LOGDIE "An unknown error has happened during Clearquest connection. Please report this issue.";
	}
	
	DEBUG "Connection established.";
	return $session;
}

sub makeQuery {
	my $typeOfQuery = shift;
	my $fieldsToRetrieve = shift;
	my $filtersToApply = shift;
	my %options = @_;
	
	my ($sortingToApply, $genericValues);

	$sortingToApply = $options{'-SORT_BY'} if $options{'-SORT_BY'};
	$genericValues = $options{'-GENERIC_VALUES'} if $options{'-GENERIC_VALUES'};
	
	my $querydef = $session->BuildQuery($typeOfQuery);
	
	# Building list of fields to retrieve
	foreach my $field (@$fieldsToRetrieve) {
		DEBUG "Adding Field \"$field\" for query.";
		$querydef->BuildField($field); 
	}
	
	# Building filtering of query
	DEBUG "Build filter...";
	_processQueryNode($filtersToApply, $querydef, $genericValues);
	 
	# Querying database
	DEBUG "Execute query...";
	my $rsltset = $session->BuildResultSet ($querydef); 
	$rsltset->Execute(); 

	##########################################
	# Building records list
	##########################################
	my $num_records = 0; 
	my @results = ();
	my $status = $rsltset->MoveNext;
	my $num_results = $rsltset->GetNumberOfColumns * 2;
	while ($status == $CQPerlExt::CQ_SUCCESS ) { 
		my $result = $rsltset->GetAllColumnValues(0);
		$num_records++; 

		my %result = ();
		for(my $column = 0; $column < $num_results; $column += 2)
		{
			$result{lc($result->[$column])} = $result->[$column+1];
		}
		
		push(@results, \%result);
		$status = $rsltset->MoveNext;
	}
	
	DEBUG "Found ".scalar(@results)." results";
	
	my $results = \@results;
	$results = sortQuery($results, $sortingToApply) if $sortingToApply;
	
	return $results;
}

sub sortQuery {
	my ($results, $sortedFields) = @_;
	return $results unless $sortedFields;
	@$results = sort { 
	foreach my $field (@$sortedFields) 
	{ 	ERROR "field \"$field\" cannot be used for sorting because it is not defined" and next unless exists($a->{$field});
		my $result = "$a->{$field}" cmp "$b->{$field}";
			return $result if $result != 0;
	} 
	return 0;
	} @$results;
	
	return $results;
}

sub _processQueryNode {
	my ($node, $parentQuery, $genericValues) = @_;
	
	my $OPERATOR = 'AND';
	
	if ($node->{operator}) {
		$OPERATOR = $node->{operator};
		delete($node->{operator});
	}

	$OPERATOR = BOOL_OP_AND if $OPERATOR ne 'OR';
	$OPERATOR = BOOL_OP_OR if $OPERATOR eq 'OR';
	my $queryNode = $parentQuery->BuildFilterOperator($OPERATOR); 
	DEBUG "Using operator $OPERATOR to associate fields/nodes";
	
	if($node->{node}) {
		if (ref($node->{node}) eq 'ARRAY') {
			foreach my $node (@{$node->{node}}) {
				_processQueryNode($node, $queryNode, $genericValues);
			}
		}
		else {
			_processQueryNode($node->{node}, $queryNode, $genericValues);
		}

		delete($node->{node});
	}
	
	foreach my $column (keys %$node) {
		my $CQ_OPERATION = 'IN';
		my $value = $node->{$column};
		
		if (ref($value) eq 'HASH') {
			$CQ_OPERATION = $value->{operator};
			$value = $value->{content};
		}

		if($genericValues and $value) {
			if($value =~ /^\*\*(.*)\*\*$/) {
				my $genericKey = $1;
				LOGDIE "Generic key \"$genericKey\" is not defined" unless exists($genericValues->{$genericKey});
				$value = $genericValues->{$genericKey};
				DEBUG "Found generic key \"$genericKey\", replaced by \"$value\"";

			}
		}
		
		my @list;
		@list = split(/\s*,\s*/, $value) if $value;
		
		$CQ_OPERATION = COMP_OP_EQ if $CQ_OPERATION eq 'EQ'; # Equality operator (=)
		$CQ_OPERATION = COMP_OP_NEQ if $CQ_OPERATION eq 'NEQ'; # Inequality operator (<>)
		$CQ_OPERATION = COMP_OP_LT if $CQ_OPERATION eq 'LT'; # Less-than operator (<)
		$CQ_OPERATION = COMP_OP_LTE if $CQ_OPERATION eq 'LTE'; # Less-than or Equal operator (<=)
		$CQ_OPERATION = COMP_OP_GT if $CQ_OPERATION eq 'GT'; # Greater-than operator (>)
		$CQ_OPERATION = COMP_OP_GTE if $CQ_OPERATION eq 'GTE'; # Greater-than or Equal operator (>=)
		$CQ_OPERATION = COMP_OP_LIKE if $CQ_OPERATION eq 'LIKE'; # Like operator (value is a substring of the string in the given field)
		$CQ_OPERATION = COMP_OP_NOT_LIKE if $CQ_OPERATION eq 'NOT_LIKE'; # Not-like operator (value is not a substring of the string in the given field)
		$CQ_OPERATION = COMP_OP_BETWEEN if $CQ_OPERATION eq 'BETWEEN'; # Between operator (value is between the specified delimiter values)
		$CQ_OPERATION = COMP_OP_NOT_BETWEEN if $CQ_OPERATION eq 'NOT_BETWEEN'; # Not-between operator (value is not between specified delimiter values)
		$CQ_OPERATION = COMP_OP_IS_NULL if $CQ_OPERATION eq 'IS_NULL'; # Is-NULL operator (field does not contain a value)
		$CQ_OPERATION = COMP_OP_IS_NOT_NULL if $CQ_OPERATION eq 'IS_NOT_NULL'; # Is-not-NULL operator (field contains a value)
		$CQ_OPERATION = COMP_OP_IN if $CQ_OPERATION eq 'IN'; # In operator (value is in the specified set)
		$CQ_OPERATION = COMP_OP_NOT_IN if $CQ_OPERATION eq 'NOT_IN'; # Not-in operator (value is not in the specified set)
			
		$queryNode->BuildFilter($column, $CQ_OPERATION, \@list);
		DEBUG "Include all colums \"$column\" with filter type \"$CQ_OPERATION\" and values (".join(" / ",@list).")";
	}
}

sub disconnectCQ {
	CQSession::Unbuild($session);
	$session = undef;
	
	WARN "This function is not finished";
}

sub getEntityFields {
	my ($entity, %args) = @_;
	
	
	my %item;
	if($args{'-Field'}) {
		my $fieldinfoobj = $entity->GetFieldValue($args{'-Field'}); 
		return $fieldinfoobj->GetValue();
	}
	elsif($args{'-Fields'}) {
		my $list = $entity->GetFieldStringValues($args{'-Fields'});
		my $index = 0;
		foreach my $fieldname (@{$args{'-Fields'}}) {
			$item{$fieldname} = $list->[$index++];
		}
	}
	else {
		my $fieldvalues = $entity->GetAllFieldValues(); 
		my $numfields = $fieldvalues->Count();
		my $x;
		for ($x = 0; $x < $numfields ; $x++) { 
			my $field = $fieldvalues->Item($x); 
			$item{$field->GetName()} = $field->GetValue();
		}
	}
	return %item;
}

sub getDuplicatesAsString {
	my ($entity, %args) = @_;
	return unless $entity->HasDuplicates();
	my $dups = $entity->GetAllDuplicates();
	my @DuplicatesList;
	my $count = $dups->Count();
	INFO "Found $count entity";
	my $x;
	for ($x = 0; $x < $count ; $x++) { 
		my $dupvar = $dups->Item($x); 
		push @DuplicatesList, $dupvar->GetChildEntityId();
	}
	return @DuplicatesList;
}

sub getEntity {
	my ($entityType, $entityDisplayedID, %args) = @_;
	DEBUG "Retrieving \"$entityDisplayedID\" of type \"$entityType\"";
	my $entity = $session->GetEntity($entityType, $entityDisplayedID);
}

sub makeEntity {
	my ($entityType, %args) = @_;
	return $session->BuildEntity($entityType);
}

sub editEntity {
	my ($entity, $action, %args) = @_;
	$session->EditEntity($entity,$action);
}

sub changeFields {
	my ($entity, %args) = @_;
	my $everything_ok = 1;
	foreach my $field (@{$args{'-OrderedFields'}}) {
		my $result = $entity->SetFieldValue("$field->{FieldName}", "$field->{FieldValue}");
		if($result ne '') {
			ERROR "Error while trying to set property \"$field->{FieldName}\" with \"$field->{FieldValue}\" for following reason : \"$result\"";
			$everything_ok = 0;
		}
	}
	foreach my $fieldName(keys %{$args{'-Fields'}}) {
		my $value = "$args{'-Fields'}->{$fieldName}";
		LOGDIE "Incorrect field (\"$fieldName\") or value (\"$value\")" unless ref($fieldName) eq '' and ref($value) eq '';
		my $result = $entity->SetFieldValue("$fieldName", "$value");
		if($result ne '') {
			ERROR "Error while trying to set property \"$fieldName\" with \"$value\" for following reason : $result";
			$everything_ok = 0;
		}		
	}
	return $everything_ok;
}

sub getAvailableActions {
	my ($entity, %args) = @_;
	return @{$entity->GetLegalAccessibleActionDefNames()};
}

sub isActionAvailable {
	my ($entity, $action, %args) = @_;
	my @fields = getAvailableActions($entity);
	my @fieldsOK = grep(/^$action$/, @fields);
	return (scalar(@fieldsOK) > 0);
}

sub getFieldsRequiredness {
	my ($entity, %args) = @_;
	my $fieldNameList = $entity->GetFieldNames(); 
	my %list;
	foreach my $fieldname (@$fieldNameList) { 
		my $requiredness = $entity->GetFieldRequiredness($fieldname);
		$list{$fieldname} = 'USE_HOOK' if($requiredness eq USE_HOOK);
		$list{$fieldname} = 'READONLY' if($requiredness eq READONLY);
		$list{$fieldname} = 'MANDATORY' if($requiredness eq MANDATORY);
		$list{$fieldname} = 'OPTIONAL' if($requiredness eq OPTIONAL);
	}
	return %list;
}

sub makeChanges {
	my ($entity, %args) = @_;
	return 0 unless _makeCQValidation($entity, %args);
	return 0 unless _makeCQCommit($entity, %args);
	return 1;
}

sub cancelAction {
	my ($entity, %args) = @_;
	$entity->Revert();
}

sub _makeCQValidation {
	my ($entity, %args) = @_;
	my $RetVal;
	
	DEBUG "Trying to validate Entity : $entity";
	eval { $RetVal = $entity->Validate(); };
	# EXCEPTION information is in $@ 
	# RetVal is either an empty string or contains a failure message string 
	if ($@){ 
		ERROR "Exception while validating: ’$@’"; 
	}
	if ($RetVal eq '') {
		DEBUG "Clearquest validation passed successfully";

		return 1;
	}
	else {
		ERROR "Validation of bug has failed on Clearquest side for following reason(s) : $RetVal";
	}
	return 0;
}

sub _makeCQCommit {
	my ($entity, %args) = @_;
	my $RetVal;
	
	DEBUG "Trying to commit Entity : $entity";
	eval {$RetVal = $entity->Commit(); };
	# EXCEPTION information is in $@ 
	# RetVal is either an empty string or contains a failure message string 
	if ($@){ 
		ERROR "Exception while commiting: ’$@’"; 
		$entity->Revert();
	}
	if ($RetVal eq '') {
		return 1;
	}
	else {
		ERROR "Commit of bug has failed on Clearquest side for following reason(s) : $RetVal";
		$entity->Revert();
	}
	return 0;
}

sub getChilds {
	my ($entity, %args) = @_;
	my $field = getEntityFields($entity, -Field => 'child_record');
	my @fields = split(/\n/, $field);
	return @fields;
}

1;