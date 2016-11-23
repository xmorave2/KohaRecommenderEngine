package Koha::Plugin::Com::Liliputech::RecommenderEngine;

## It's good practive to use Modern::Perl
use Modern::Perl;
use Data::Dumper;
use DateTime;

## Required for all plugins
use base qw(Koha::Plugins::Base);

## We will also need to include any Koha libraries we want to access
use C4::Context;
use C4::Branch;
use C4::Members;
use C4::Auth;

## Here we set our plugin version
our $VERSION = 1.00;

## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name   => 'Koha Recommender Plugin',
    author => 'Arthur O Suzuki',
    description => 'This plugin implements recommendations for each Bibliographic reference based on all other borrowers old issues',
    date_authored   => '2016-06-27',
    date_updated    => '2016-11-18',
    minimum_version => '3.18.13.000',
    maximum_version => undef,
    version         => $VERSION,
};

## This is the minimum code required for a plugin's 'new' method
## More can be added, but none should be removed
sub new {
    my ( $class, $args ) = @_;

    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual $self
    my $self = $class->SUPER::new($args);

    return $self;
}

sub install() {
    my ( $self, $args ) = @_;
    my $dbh = C4::Context->dbh;
    
    ## Setup default configuration.
    
    ## First fetch value if UNIMARC or MARC21
    my $query = "select value from systempreferences where variable='marcflavour'";
    my $sth = $dbh->prepare($query);
    $sth->execute();
    my $marcflavour = ${$dbh->selectcol_arrayref($query)}[0];
    
    ## Create ExtractValue query according to MARC format
    my $marcfilter;
	if ($marcflavour eq 'UNIMARC') {
        $marcfilter = "ExtractValue(marcxml,'//datafield[\@tag=\"200\"]/subfield[\@code=\"a\"]')";
	} elsif ($marcflavour eq 'MARC21') {
        $marcfilter = "ExtractValue(marcxml,'//datafield[\@tag=\"245\"]/subfield[\@code=\"a\"]')";
    }

    ## Set content filter to empty string
    my $contentfilter = '';

    ## Set number of recommendation to display on OPAC to 10 by default (fast execution)
    my $recordnumber = 10;

    ## Set Issues interval analysis to 5 YEAR (Pure SQL)
    my $interval = '5 YEAR';
    
    $self->store_data(
        {
            marcfilter => $marcfilter,
            contentfilter => $contentfilter,
            recordnumber => $recordnumber,
            interval => $interval,
            last_configured_at => DateTime->now,
            last_configured_by => C4::Context->userenv->{'number'},
        }
    );
    return 1;
}

## This method will be run just before the plugin files are deleted
## when a plugin is uninstalled. It is good practice to clean up
## after ourselves!
sub uninstall() {
    my ( $self, $args ) = @_;

    # Removing Plugin JS from Syspref
    my $opacuserjs = C4::Context->preference('opacuserjs');
    $opacuserjs =~ s/\n\/\* JS for Koha Recommender Plugin.*End of JS for Koha Recommender Plugin \*\///gs;
    C4::Context->set_preference( 'opacuserjs', $opacuserjs );
}

sub AddSlashes {
    my $text = shift;
## Make sure to do the backslash first!
    $text =~ s/\\/\\\\/g;
    $text =~ s/'/\\'/g;
    $text =~ s/"/\\"/g;
    $text =~ s/\\0/\\\\0/g;
    return $text;
}
 
sub configure() {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    unless ( $cgi->param('save') ) {
        my $template = $self->get_template( { file => 'configure.tt' } );
        my $dbh = C4::Context->dbh;

       ## Grab the values we already have for our settings, if any exist
       ## And apply to configure template
       my $sanitizedmarcfilter = $self->retrieve_data('marcfilter');
 
       $template->param(
#                marcfilter => $sanitizedmarcfilter,
                contentfilter => $self->retrieve_data('contentfilter'),
                recordnumber => $self->retrieve_data('recordnumber'),
                interval => $self->retrieve_data('interval'),
                last_configured_at => $self->retrieve_data('last_configured_at'),
                last_configured_by => $self->retrieve_data('last_configured_by'),
       );

        #Could be like this :
        #my $contentfilter = "and items.statisticvalue in (select distinct statisticvalue from items where biblioitemnumber = '$biblionumber')";
 
        print $cgi->header(
            {
                -type     => 'text/html',
                -charset  => 'UTF-8',
                -encoding => "UTF-8"
            }
                );
        print $template->output();
    }

    else {
        my $marcfilter = $cgi->param('marcfilter');
        my $contentfilter = $cgi->param('contentfilter');
        my $recordnumber = $cgi->param('recordnumber');
        my $interval = $cgi->param('interval');

        $self->store_data(
            {
 #               marcfilter => $marcfilter,
                contentfilter => $contentfilter,
                recordnumber => $recordnumber,
                interval => $interval,
                last_configured_at => DateTime->now,
                last_configured_by => C4::Context->userenv->{'number'},
            }
        );

        $self->updateJS($recordnumber);
        $self->go_home();
    }
    return 1;
}

sub updateJS() {
    my ($self, $recordnumber) = @_;

    my $opacuserjs = C4::Context->preference('opacuserjs');
    $opacuserjs =~ s/\n\/\* JS for Koha Recommender Plugin.*End of JS for Koha Recommender Plugin \*\///gs;

    my $template = $self->get_template( { file => 'opacuserjs.tt' } );
    $template->param( 'recordnumber' => $recordnumber );
    my $recommender_js = $template->output();

    $recommender_js = qq|\n/* JS for Koha Recommender Plugin 
   This JS was added automatically by installing the Recommender plugin
   Please do not modify */\n|
      . $recommender_js
      . q|/* End of JS for Koha Recommender Plugin */|;

    $opacuserjs .= $recommender_js;
    C4::Context->set_preference( 'opacuserjs', $opacuserjs );
}

## The existance of a 'report' subroutine means the plugin is capable
## of running a report. This example report can output a list of patrons
## either as HTML or as a CSV file. Technically, you could put all your code
## in the report method, but that would be a really poor way to write code
## for all but the simplest reports
sub report {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    unless ( scalar $cgi->param('biblionumber') ) {
        $self->report_step1();
    }
    else {
        $self->report_step2();
    }
}

## These are helper functions that are specific to this plugin
## You can manage the control flow of your plugin any
## way you wish, but I find this is a good approach
sub report_step1 {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $template = $self->get_template({ file => 'report-step1.tt' });

    print $cgi->header();
    print $template->output();
}

sub report_step2 {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};
    my $dbh = C4::Context->dbh;

    ## Get configuration
    my $marcfilter = $self->retrieve_data('marcfilter');
    my $contentfilter = $self->retrieve_data('contentfilter');
    my $recordnumber = $self->retrieve_data('recordnumber');
    my $interval = $self->retrieve_data('interval');

    ##Biblionumber to query
    my $biblionumber = scalar $cgi->param('biblionumber');

    ##Choose how to output data (set to html if undefined)
    my $template;
    my $output = scalar $cgi->param('output');
    if ($output eq 'csv') {
        $template = $self->get_template({ file => 'report-step2-csv.tt' });
        print "Content-type: text/csv\n\n";
    }
    elsif ($output eq 'json') {
        $template = $self->get_template({ file => 'report-step2-json.tt' });
        print "Content-type: application/json\n\n";
    }
    else {
        $template = $self->get_template({ file => 'report-step2.tt' });
        print "Content-type: text/html\n\n";
    }

    ##Eventually set a limit to the number of results to display
    my $limit = "";
    if($recordnumber) {
        $limit = "limit $recordnumber";
    }
    
    ## Wow such a big shit...

    my $query = "
	select suggestions.biblioitemnumber as biblionumber, $marcfilter AS title, totalPrets as nissues from biblioitems
	inner join (
	select distinct biblioitemnumber, sum(pretExemplaire) totalPrets from items inner join (
		select distinct itemnumber, count(itemnumber) pretExemplaire from old_issues
		where
		issuedate > DATE_SUB(NOW(),INTERVAL $interval) and
		itemnumber is not null and borrowernumber is not null and
		borrowernumber in (
			select distinct borrowernumber from old_issues
			where borrowernumber is not null and itemnumber IN (
				select itemnumber from items where biblioitemnumber = '$biblionumber'
			)
		) group by itemnumber
	) exemplaires on items.itemnumber=exemplaires.itemnumber
	where biblioitemnumber <> '$biblionumber'
	$contentfilter
	group by biblioitemnumber
	order by totalPrets desc, Rand()
	$limit) suggestions
	on biblioitems.biblioitemnumber=suggestions.biblioitemnumber";

    my $sth = $dbh->prepare($query);
    $sth->execute();

    my @results;
    while ( my $row = $sth->fetchrow_hashref() ) {
        push( @results, $row );
    }
 
    $template->param(
	biblionumber => $biblionumber,
        results => \@results
    );

    print $template->output();
}
1;
