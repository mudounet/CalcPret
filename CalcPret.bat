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
};

INFO("Starting program (V ".PROGRAM_VERSION.")");

#########################################################
# loading of Configuration files
#########################################################
my $config = _loadConfig("./InitConfig/","CalcPret.config.xml",undef, KeyAttr => {}, ForceArray => qr/^(charge|apport|pret|revenu)$/);

my %output;

#########################################################
# Calcul du coût total de l'opération
#########################################################
$output{"Cout total"} = 0;

foreach my $charge (@{$config->{bien_immobilier}->{charge}}) {
	INFO "Traitement de la partie \"$charge->{name}\" du bien immobilier";
	
	$output{"Cout total"} += $charge->{montant};
}

#########################################################
# Mise en place des échéances des revenus
#########################################################
foreach my $charge (@{$config->{revenus}->{revenu}}) {
	INFO "Traitement de la partie \"$charge->{name}\" du bien immobilier";
	
	$output{echeances}[$charge->{echeance}]{revenu} += $charge->{montant};
}

#########################################################
# Déduction des apports personnels
#########################################################
$output{"Apports personnels"} = 0;
foreach my $charge (@{$config->{apports}->{apport}}) {
	INFO "Déduction de l'apport \"$charge->{name}\" du bien immobilier";
	
	$output{"Apports personnels"} += $charge->{montant};
}

#########################################################
# Calcul des échéances
#########################################################
my $capital_restant_du = $output{"Cout total"} - $output{"Apports personnels"};
$output{echeances}[0]{capital_a_rembourser} = $capital_restant_du;
my $dernier_revenu = $output{echeances}[0]{revenu};
$output{synthese}{assurance} =0;
$output{synthese}{interets_total} = 0;
$output{synthese}{echeances} = 0;

while($capital_restant_du > 0) {
	++$output{synthese}{echeances};
	my $echeance = $output{synthese}{echeances};

	INFO "Calcul de l'echeance $echeance (".($echeance/12).") ...";

	####### Calcul du revenu à prendre en compte ########################
	$dernier_revenu = $output{echeances}[$echeance]{revenu} if($output{echeances}[$echeance]{revenu});
	$output{echeances}[$echeance]{revenu} = $dernier_revenu;

	####### Calcul du montant des interets ##########################
	my $interets = 0;
	
	DEBUG "Montant des interets : $interets";

	
	####### Calcul du montant de l'assurance ########################
	$output{echeances}[$echeance]{assurance} = ($config->{assurance}->{taux} /1200) * $capital_restant_du;	
	$output{synthese}{assurance} += $output{echeances}[$echeance]{assurance};
	DEBUG "Montant de l'assurance : $output{echeances}[$echeance]{assurance}";

	
	####### Calcul du capital remboursé #############################
	if($capital_restant_du < $dernier_revenu) {
		$output{echeances}[$echeance]{capital_rembourse} = $capital_restant_du;
	}
	else {
		$output{echeances}[$echeance]{capital_rembourse} = $dernier_revenu - $interets - $output{echeances}[$echeance]{assurance};
	}
	
	$capital_restant_du = $capital_restant_du - $output{echeances}[$echeance]{capital_rembourse};
	$output{echeances}[$echeance]{capital_a_rembourser} = $capital_restant_du;
}

open FILE,">output.txt";
print FILE Dumper(\%output);
close FILE;

print Dumper($output{synthese});

__END__
:endofperl
pause