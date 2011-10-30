use Tk::ROText;
use Tk::JComboBox;

#my $balloon = $mw->Balloon();

sub addListBox {
	my ($parentElement, $labelName, $listToInsert, $selectedField, %args) = @_;
	
	my %item;
	if($args{'-searchable'}) {
		$item{searchEnabled} = 1;
	}
	
	$item{selection} = $selectedField;
	$item{mainFrame} = $parentElement->Frame()-> pack( -fill => 'x', -expand => 1);
	$item{label} = $item{mainFrame}->Label(-text => $labelName, -width => 15 )->pack( -side => 'left' );
	if($item{searchEnabled}) {
		my %completeList;
		if (ref $listToInsert eq "ARRAY") {
			foreach my $item (@$listToInsert) {
				$completeList{$item} = $item;
			}
		}
		elsif(ref $listToInsert eq "HASH") { %completeList = %$listToInsert; }
		
		my @list;
		$item{selectedList} = \@list;
		$item{searchActivated} = 0;
		$item{searchFrame} = $item{mainFrame}->pack();
		$item{searchButton} = $item{searchFrame}->Button(-text => 'Search', -command => sub { manageSearchBox(\%item) })->pack( -side => 'right' );

		$item{subsearchFrame} = $item{searchFrame}->Frame();
		$item{searchDescription} = $item{subsearchFrame}->Label(-textvariable => \$item{searchText})->pack(-side => 'left');
		$item{subsearchFrame}->Entry(-validate => 'all', -textvariable => \$item{search}, -width => 15, -validatecommand => sub { my $search = shift; search(\%item, $search); return 1; } )->pack(-side => 'right');
	}
	else {
		$item{selectedList} = $listToInsert;
	}
	$item{listbox} = $item{mainFrame}->JComboBox(-choices => $item{selectedList}, -textvariable => $item{selection})->pack(-fill => 'x', -side => 'left', -expand => 1);

	#changeList(\%item, \%completeList, $$selectedField) if %completeList;
	
	return \%item;
}

sub addDescriptionField {
	my ($container, $text, $CQ_Field, %args) = @_;
	
	my %item;
	$item{selection} = $CQ_Field;
	$item{mainFrame} = $container->Frame() -> pack(-side => 'top', -fill => 'both', -expand => 1);
	$item{mainFrame}->Label(-text => $text, -width => 15 )->pack( -side => 'left' );
	DEBUG "Instantiate description field.";
	if($args{'-readonly'}) {
		$item{Text} = $item{mainFrame}->Scrolled("ROText", -scrollbars => 'osoe', ($args{'-height'}) ? (-height => $args{'-height'}) : () ) -> pack(-fill => 'both');
		DEBUG "Using readonly Text field";
	}
	else {
		$item{Text} = $item{mainFrame}->Scrolled("Text", -scrollbars => 'osoe', ($args{'-height'}) ? (-height => $args{'-height'}) : ()) -> pack(-fill => 'both');
		$item{Text}->bind( '<FocusOut>' => sub { ${$item{selection}} = $item{Text}->Contents(); } );
	}
	$item{Text}->Contents($$CQ_Field);

	return \%item;
}

sub center {
  my $win = shift;

  $win->withdraw;   # Hide the window while we move it about
  $win->update;     # Make sure width and height are current

  # Center window
  my $xpos = int(($win->screenwidth  - $win->width ) / 2);
  my $ypos = int(($win->screenheight - $win->height) / 2);
  $win->geometry("+$xpos+$ypos");

  $win->deiconify;  # Show the window again
}

sub manageSearchBox {
	my $searchListbox = shift;
	
	$searchListbox->{searchActivated} = ($searchListbox->{searchActivated}+1)%2;
	if($searchListbox->{searchActivated}) {
		DEBUG "Search activated";
		$searchListbox->{searchButton}->configure(-text => 'X');
		$searchListbox->{subsearchFrame}->pack(-fill => 'x', -side => 'right', -anchor => 'center');
		#$balloon->attach($searchListbox->{searchButton}, -msg => 'Cancel search');
	}
	else {
		DEBUG "Search deactivated";
		$searchListbox->{search} = '';
		$searchListbox->{searchButton}->configure(-text => 'Search');
		$searchListbox->{subsearchFrame}->packForget();
		#$balloon->attach($searchListbox->{searchButton}, -msg => 'Perform a search on left list');
	}
}

sub changeList {
	my $item = shift;
	my $completeList = shift;
	my $selection = shift;
	
	$item->{completeList} = $completeList;

	my @list = sort keys %$completeList;
	@{$item->{selectedList}} = @list;
	$item->{searchButton}->configure(-state => (scalar(@list))?'normal':'disabled');
	$item->{listbox}->configure(-state => (scalar(@list))?'normal':'disabled');
	
	DEBUG "Trying to set default value \"$selection\"" and $item->{listbox}->setSelected($selection) if $selection;
}

sub search {	
	my $searchListbox = shift;
	my $search = shift;
	
	DEBUG "Search request is : \"$search\"";
	my @tmpList;
	my %completeList = %{$searchListbox->{completeList}};
	my @resultsText = ("Hereafter are results remainings:");
	my $old_selection = ${$searchListbox->{selection}};
	foreach my $item (keys %completeList) {
		next unless (not $search or $search eq '' or $item =~ /$search/i or $completeList{$item} =~ /$search/i);
		push (@tmpList, $item);
		push (@resultsText, " => $item --- $completeList{$item}");
	}
	my $nbrOfResults = scalar(@tmpList);
	@{$searchListbox->{selectedList}} = sort @tmpList;
	${$searchListbox->{selection}} = $old_selection if $old_selection;
	${$searchListbox->{selection}} = $tmpList[0] if $nbrOfResults == 1;

	#$balloon->attach($searchListbox->{searchDescription}, -msg => join("\n", @resultsText));
	$searchListbox->{listbox}->configure(-state => $nbrOfResults ? 'normal' : 'disabled');
	$searchListbox->{searchText} = ($nbrOfResults ? ($nbrOfResults == 1 ? "1 result" : $nbrOfResults.' results' ) : 'No results');
	return 1;
}



sub cancel {
	my $mw = shift;
	
	my $response = $mw->messageBox(-title => "Confirmation requested", -message => "Do you really want to quit this application?", -type => 'yesno', -icon => 'question');
	
	DEBUG "User has answered \"$response\" to cancellation question";
	return unless $response eq "Yes";
	INFO "User has requested a cancellation";
	exit(1001);
}

1;