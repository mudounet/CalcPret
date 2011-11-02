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
# Déduction des apports personnels
#########################################################
$output{"Apports personnels"} = 0;
foreach my $charge (@{$config->{apports}->{apport}}) {
	INFO "Deduction de l'apport \"$charge->{name}\" du bien immobilier";
	
	$output{"Apports personnels"} += $charge->{montant};
}

#########################################################
# Mise en place des échéances des revenus
#########################################################
my @echeances;
foreach my $charge (@{$config->{revenus}->{revenu}}) {
	INFO "Traitement de la partie \"$charge->{name}\" du bien immobilier";
	
	$echeances[$charge->{echeance}]{revenu} += $charge->{montant};
}

#########################################################
# Calcul des différents prêts
#########################################################
my %prets;
my $pret_sans_montant_ref = undef;
my $restant_pret = $output{"Cout total"} - $output{"Apports personnels"};
foreach my $pret (@{$config->{prets}->{pret}}) {
	INFO "Calcul des parametres du pret \"$pret->{name}\"";
	my %param_pret = ( capital => $pret->{montant}, mensualites => $pret->{mensualites}, echeances => $pret->{echeances}, taux => $pret->{taux});
	if(ref($pret->{montant}) eq "" && $pret->{montant} > 0) {
		DEBUG "Pret renseigne trouve";
		%param_pret = completer_donnees_pret(\%param_pret, $config->{assurance}->{taux});
		$restant_pret -= $param_pret{capital}; 
		$prets{$pret->{name}} = \%param_pret;
	} else {
		if(!$pret_sans_montant_ref) {
			DEBUG "Pret sans montant detecte";
			$pret_sans_montant_ref = \%param_pret;
		}
		else {
			LOGDIE "Plusieurs prets sans montant detectes."
		}
	}
}

if($pret_sans_montant_ref) {
	INFO "Calcul du montant a partir des autres prets.";
	$pret_sans_montant_ref->{capital} = $restant_pret;
}
my %pret_sans_montant = %$pret_sans_montant_ref;



#########################################################
# Calcul des échéances
#########################################################
my @echeances_autres_prets;
while (my ($key, $value) = each(%prets)){
    DEBUG "Calcul des echeances du pret \"".$key."\"";
	my %pret_detail = calcul_detail_echeances($value, \@echeances, \@echeances_autres_prets);
	
	open FILE,">details_$key.txt";
	print FILE Dumper(\%pret_detail);
	close FILE;
}

#print Dumper($output{synthese});

############################################################################
# Fonctions de calcul
############################################################################
sub calcul_detail_echeances {
	my ($param_pret_ref) = @_;
	my %param_pret = %$param_pret_ref;
	my %donnees_pret;
	
	my $capital_restant_du = $param_pret{capital};
	$donnees_pret{echeances}[0]{capital_a_rembourser} = $capital_restant_du;

	#my $dernier_revenu = $echeances[0]{revenu};
	$donnees_pret{synthese}{assurance} = 0;
	$donnees_pret{synthese}{interets} = 0;
	$donnees_pret{synthese}{echeances} = 0;

	while($capital_restant_du > 0) {
		++$donnees_pret{synthese}{echeances};
		my $echeance = $donnees_pret{synthese}{echeances};

		DEBUG "Calcul de l'echeance $echeance (".($echeance/12).") ...";

		####### Calcul du montant des interets ##########################
		$donnees_pret{echeances}[$echeance]{interets} = ($param_pret{taux}/1200)*$capital_restant_du;
		$donnees_pret{synthese}{interets} += $donnees_pret{echeances}[$echeance]{interets};
		DEBUG "Montant des interets : $donnees_pret{echeances}[$echeance]{interets}";
		
		####### Calcul du montant de l'assurance ########################
		$donnees_pret{echeances}[$echeance]{assurance} = ($config->{assurance}->{taux} /1200) * $capital_restant_du;	
		$donnees_pret{synthese}{assurance} += $donnees_pret{echeances}[$echeance]{assurance};
		DEBUG "Montant de l'assurance : $donnees_pret{echeances}[$echeance]{assurance}";

		####### Calcul du revenu à prendre en compte ########################
		my $montant_echeance = $param_pret{mensualites};
		if(!$montant_echeance) {
			$montant_echeance = $donnees_pret{echeances}[$echeance]{echeance} if($donnees_pret{echeances}[$echeance]{revenu});
		}
		$donnees_pret{echeances}[$echeance]{echeance} = $montant_echeance;	
	
		####### Calcul du capital remboursé #############################
		if($capital_restant_du < $montant_echeance) {
			$donnees_pret{echeances}[$echeance]{capital_rembourse} = $capital_restant_du;
		}
		else {
			$donnees_pret{echeances}[$echeance]{capital_rembourse} = $montant_echeance - $donnees_pret{echeances}[$echeance]{interets} - $donnees_pret{echeances}[$echeance]{assurance};
		}
		
		$capital_restant_du = $capital_restant_du - $donnees_pret{echeances}[$echeance]{capital_rembourse};
		$donnees_pret{echeances}[$echeance]{capital_a_rembourser} = $capital_restant_du;
	}	
	return %donnees_pret;
}

sub completer_donnees_pret {
	my ($param_pret, $taux_assurance) = @_;
	if(!($param_pret->{taux} && $param_pret->{capital} && $param_pret->{echeances})) {
		LOGDIE "Donnees incompletes : ".Dumper($param_pret);
	}
	elsif (!$param_pret->{mensualite}) {
		return calc_mensualites($param_pret, $taux_assurance);	
	} else {
		LOGDIE "Mode de calcul non défini.";
	}
}

sub calc_mensualites {
	my ($param_pret, $taux_assurance) = @_;
	$taux_assurance = 0 unless $taux_assurance;
	my $taux = ($param_pret->{taux} + $taux_assurance) / 1200;
	my $capital = $param_pret->{capital};
	my $echeances = $param_pret->{echeances};
	$param_pret->{mensualites} = $capital * $taux / ( 1 - 1/((1 + $taux)**($echeances)));
	return %$param_pret;
}

__END__
:endofperl
pause