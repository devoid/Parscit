package ParsCit::Controller;

###
# This package is used to pull together various citation
# processing modules in the ParsCit distribution, serving
# as a script for handling the entire citation processing
# control flow.  The extractCitations subroutine should be
# the only needed API element if XML output is desired;
# however, the extractCitationsImpl subroutine can be used
# to get direct access to the list of citation objects.
#
# Isaac Councill, 07/23/07
###

require 'dumpvar.pl';

use strict;
# Local libraries
use ParsCit::Config;
use ParsCit::Tr2crfpp;
use ParsCit::PreProcess;
use ParsCit::PostProcess;
use ParsCit::CitationContext;
# Dependencies
use CSXUtil::SafeText qw(cleanXML);

###
# Main API method for generating an XML document including
# all citation data.  Returns a reference XML document and
# a reference to the article body text.
###

# Extract citations from text
sub extractCitations 
{
    my ($text_file) = @_;

	# Real works are in there
    my ($status, $msg, $citations, $body_text) = extractCitationsImpl($text_file);

	# Check the result status
    if ($status > 0) 
	{
		return buildXMLResponse($citations);
    } 
	else 
	{
		# Return error message
		my $error = "Error: " . $msg; return \$error;
    }
} 

sub extractCitationsAlreadySegmented 
{
    my ($text_file) = @_;

    my ($status, $msg) = (1, "");

	# Cannot open input file, return error message
    if (! open(IN, "<:utf8", $text_file)) {	return (-1, "Could not open file " . $text_file . ": " . $!); }

	#
    my @raw_citations		= ();
    my $current_citation	= undef;

	while (<IN>) 
	{
		# Remove eol
		chomp();
	
		# Save current citation
		if (m/^\s*$/ && defined $current_citation) 
		{
	    	my $cite = new ParsCit::Citation();
	    	$cite->setString($current_citation);
	    	push @raw_citations, $cite;
	    	$current_citation = undef;
	    	next;
		}

		# Current citation eq current line
		if (! defined $current_citation) 
		{
	    	$current_citation = $_;
		}
		# Append the current line to the current citation
		else 
		{
	    	$current_citation = $current_citation . " " . $_;
		}
    }

	# Close the input after reading
    close IN;

	# Save the last citation
	if (defined $current_citation) 
	{
		my $cite = new ParsCit::Citation();
		push @raw_citations, $cite;
    }

    my @citations 				= ();
    my @valid_citations			= ();
    my $normalized_cite_text	= "";

    foreach my $citation (@raw_citations) 
	{
		# Tr2cfpp needs an enclosing tag for initial class seed.
		my $cite_string = $citation->getString();

		if (defined $cite_string && $cite_string !~ m/^\s*$/) 
		{
	    	$normalized_cite_text .= "<title> " . $citation->getString() . " </title>\n";
			push @citations, $citation;
		}
    }

	# Stop - nothing left to do.
    if ($#citations < 0) { return ($status, $msg, \@valid_citations); }

    my $tmpfile = ParsCit::Tr2crfpp::prepData(\$normalized_cite_text, $text_file);
    my $outfile = $tmpfile . "_dec";

    if (ParsCit::Tr2crfpp::decode($tmpfile, $outfile))
	{
		my ($raw_xml, $cite_info, $tstatus, $tmsg) = ParsCit::PostProcess::readAndNormalize($outfile);

		if ($tstatus <= 0) { return ($tstatus, $msg, undef, undef); }

		my @all_cite_info = @{ $cite_info };

		if ($#citations == $#all_cite_info) 
		{
	    	for (my $i = 0; $i <= $#citations; $i++) 
			{
				my $citation	= $citations[ $i ];
				my %cite_hash	= %{ $all_cite_info[ $i ] };
				
				foreach my $key (keys %cite_hash)
				{
		    		$citation->loadDataItem($key, $cite_hash{ $key });
				}
		
				my $marker = $citation->getMarker();

				if (! defined $marker) 
				{
		    		$marker = $citation->buildAuthYearMarker();
		    		$citation->setMarker($marker);
				}
				
				push @valid_citations, $citation;
	    	}
		} 
		else 
		{
	    	$status	= -1;
	    	$msg	= "Mismatch between expected citations and cite info";
		}
    }

    unlink($tmpfile);
    unlink($outfile);

    return buildXMLResponse(\@valid_citations);
}

# Thang: tmp method for debugging purpose
sub printArray 
{
	my ($filename, $tokens) = @_;
  	open(OF, ">:utf8", $filename);
  	foreach (@{ $tokens }) { print OF $_, "\n"; }
	close OF;
}

###
# Main script for actually walking through the steps of citation
# processing.  Returns a status code (0 for failure), an error 
# message (may be blank if no error), a reference to an array of 
# citation objects and a reference to the body text of the article
# being processed.
###
sub extractCitationsImpl 
{
    my ($textfile, $bwrite_split) = @_;

    if (! defined $bwrite_split) { $bwrite_split = $ParsCit::Config::bWriteSplit; }

	# Status and error message initialization
    my ($status, $msg) = (1, "");

    if (! open(IN, "<:utf8", $textfile)) { return (-1, "Could not open text file " . $textfile . ": " . $!); }

    my $text;
    {
		local $/	= undef;
		$text		= <IN>;
    }
    close IN;

	###
    # Thang May 2010
    # Map each position in norm_body_text to a position in body_text, scalar(@pos_array) = number of tokens in norm_body_text
	my @pos_array = (); 
	# TODO: Switch this function to sectlabel module
    my ($rcite_text, $rnorm_body_text, $rbody_text) = ParsCit::PreProcess::findCitationText(\$text, \@pos_array);

    my @norm_body_tokens	= split(/\s+/, $$rnorm_body_text);
    my @body_tokens			= split(/\s+/, $$rbody_text);

	my $size	= scalar(@norm_body_tokens);
    my $size1	= scalar(@pos_array);

    if($size != $size1) { die "ParsCit::Controller::extractCitationsImpl: normBodyText size $size != posArray size $size1\n"; }
    # End Thang May 2010
	###

	# Filename initialization
    my ($citefile, $bodyfile) = ("", "");
    if ($bwrite_split > 0) { ($citefile, $bodyfile) = writeSplit($textfile, $rcite_text, $rbody_text); }

	# Extract citations from citation text
	# TODO: Train a new model to segment the citation without marker
    my $rraw_citations	= ParsCit::PreProcess::segmentCitations($rcite_text);

	my @citations		= ();
    my @valid_citations	= ();

	# Process each citation
    my $normalized_cite_text = "";
    foreach my $citation (@{ $rraw_citations }) 
	{
		# Tr2cfpp needs an enclosing tag for initial class seed.
		my $cite_string = $citation->getString();
		if (defined $cite_string && $cite_string !~ m/^\s*$/) 
		{
	    	$normalized_cite_text .= "<title> " . $citation->getString() . " </title>\n";
	    	push @citations, $citation;
		}
    }

	# Stop - nothing left to do.
    if ($#citations < 0) { return ($status, $msg, \@valid_citations, $rnorm_body_text); }

    my $tmpfile = ParsCit::Tr2crfpp::prepData(\$normalized_cite_text, $textfile);
    my $outfile = $tmpfile . "_dec";

    if (ParsCit::Tr2crfpp::decode($tmpfile, $outfile)) 
	{
		my ($rraw_xml, $rcite_info, $tstatus, $tmsg) = ParsCit::PostProcess::readAndNormalize($outfile);
		if ($tstatus <= 0) { return ($tstatus, $msg, undef, undef); }

		my @cite_info = @{ $rcite_info };

		if ($#citations == $#cite_info) 
		{
	    	for (my $i = 0; $i <= $#citations; $i++) 
			{
				my $citation	= $citations[ $i ];
				my %cite_info	= %{ $cite_info[ $i ] };
				
				foreach my $key (keys %cite_info) 
				{
		    		$citation->loadDataItem($key, $cite_info{ $key });
				}
		
				my $marker = $citation->getMarker();
				if (!defined $marker) 
				{
		    		$marker = $citation->buildAuthYearMarker();
		    		$citation->setMarker($marker);
				}
				
				###
				# Modified by Nick Friedrich
				### getCitationContext returns contexts and the position of the contexts
				###
				# Thang: Nov 2009 add $rcit_strs - in-text ciation strs
				###
				my ($rcontexts, $rpositions, $start_word_positions, $end_word_positions, $rcit_strs) = ParsCit::CitationContext::getCitationContext($rnorm_body_text, 
																																					\@pos_array, 
																																					$marker);

				###
				# Thang May 2010: add $rWordPositions, $rBodyText to find word-based positions (0-based) according to the *.body file
				###

				foreach my $context (@{ $rcontexts }) 				
				{
					# Next citation context
		    		$citation->addContext($context);
		    		
					# Next citation position
					my $position = shift @{ $rpositions };
		    		$citation->addPosition($position);
		    
					##
		    		# Thang: Nov 2009, add $rcit_strs
					###
					# Next citation string
		    		my $cit_str = shift @{ $rcit_strs };
		    		$citation->addCitStr($cit_str);
		    		# End Thang: Nov 2009

		    		# Next start and end of citation
					my $start_pos	= shift @{ $start_word_positions };
		    		my $end_pos		= shift @{ $end_word_positions };

		    		$citation->addStartWordPosition( $pos_array[ $start_pos ] );
		    		$citation->addEndWordPosition( $pos_array[ $end_pos ] );
					# print STDERR $cit_str, " --> ", $body_tokens[ $pos_array[ $start_pos ] ], " \t ", $pos_array[ $start_pos], " ### "; 
					# print STDERR $pos_array[ $end_pos], " \t ", $body_tokens[ $pos_array[ $end_pos ] ], "\n";
				}
		
				push @valid_citations, $citation;
	    	}
		} 
		else 
		{
	    	$status	= -1;
	    	$msg	= "Mismatch between expected citations and cite info";
		}
    }

    unlink($tmpfile);
    unlink($outfile);

	# Our work here is done
    return ($status, $msg, \@valid_citations, $rbody_text, $citefile, $bodyfile);
}

# Write citation list in xml format 
sub buildXMLResponse 
{
    my ($rcitations) = @_;

    my $l_alg_name		= $ParsCit::Config::algorithmName;
    my $l_alg_version	= $ParsCit::Config::algorithmVersion;

    cleanXML(\$l_alg_name);
    cleanXML(\$l_alg_version);

    my $xml	= "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" . "<algorithm name=\"$l_alg_name\" " . "version=\"$l_alg_version\">\n";
    $xml	= $xml . "<citationList>\n";

	# Write output
    foreach my $citation (@$rcitations) { $xml .= $citation->toXML(); }

    $xml .= "</citationList>\n";
    $xml .= "</algorithm>\n";
    return \$xml;

} 

# 
sub writeSplit 
{
    my ($textfile, $rcite_text, $rbody_text) = @_;

    my $citefile = changeExtension($textfile, "cite");
    my $bodyfile = changeExtension($textfile, "body");

    if (open(OUT, ">$citefile")) 
	{
		binmode OUT, ":utf8";
		print 	OUT $$rcite_text;
		close 	OUT;
    } 
	else 
	{
		print STDERR "Could not open .cite file for writing: $!\n";
    }

    if (open(OUT, ">$bodyfile")) 
	{
		binmode OUT, ":utf8";
		print 	OUT $$rbody_text;
		close 	OUT;
    } 
	else 
	{
		print STDERR "Could not open .body file for writing: $!\n";
    }

	# Our work here is done
    return ($citefile, $bodyfile);
} 

# Support function: change the extension of a file
sub changeExtension 
{
    my ($fn, $ext) = @_;
    unless ($fn =~ s/^(.*)\..*$/$1\.$ext/) { $fn .= "." . $ext; }
    return $fn;
} 

1;
