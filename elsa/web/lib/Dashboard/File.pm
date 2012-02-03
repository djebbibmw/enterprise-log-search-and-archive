package Dashboard::File;
use Moose;
use Data::Dumper;
extends 'Dashboard';

has 'file' => (is => 'rw', isa => 'Str', required => 1);

sub BUILD {
	my $self = shift;
	
	open(FH, $self->file) or die($!);
	while (<FH>){
		chomp;
		my ($description, $query_string) = split(/\,/, $_);
		push @{ $self->queries }, {
			query_string => $query_string,
			query_meta_params => {
				start => $self->start_time,
				end => $self->end_time,
				groupby => [$self->groupby],
				comment => $description,
			},
			user_info => $self->user_info,
		};
	}
	close(FH);	
	
	$self->_get_data();
	
	return $self;
}

1;