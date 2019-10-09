OpenStudio-HEScore
===============

An OpenStudio/EnergyPlus simulation workflow that operates on a HPXML file produced by DOE's Home Energy Score (HEScore).

**Unit Test Status:** [![CircleCI](https://circleci.com/gh/NREL/OpenStudio-HEScore/tree/master.svg?style=svg&circle-token=b37b6362c4ddea56d7d2fccfe6ebbb735026f824)](https://circleci.com/gh/NREL/OpenStudio-HEScore/tree/master)

## Setup

1. Either download [OpenStudio 2.9.0](https://github.com/NREL/OpenStudio/releases/tag/v2.9.0) (at a minimum, install the Command Line Interface and EnergyPlus components) or use the [nrel/openstudio docker image](https://hub.docker.com/r/nrel/openstudio).
2. Clone or download this repository's source code. 
3. To obtain all available weather files, run:  
```openstudio workflow/run_simulation.rb --download-weather``` 

## Running

Run the HEScore simulation on a provided sample HPXML file:  
```openstudio --no-ssl workflow/run_simulation.rb -x workflow/sample_files/Base_hpxml.xml```  

Run `openstudio workflow/run_simulation.rb -h` to see all available commands/arguments.

## Outputs

Upon completion, simulation results disaggregated by end use and month are available in the `workflow/results/results.json` file. 

There is also a `workflow/results/HEScoreDesign.xml`, which is the result of applying the HEScore ruleset (e.g., geometry assumptions, etc.) and is the input to the EnergyPlus simulation.

Finally, there is a `workflow/HEScoreDesign` directory that contains the EnergyPlus input and output files.

## Software Developers

To use this workflow, software tools must produce a valid HPXML file. HPXML is an flexible and extensible format, where nearly all fields in the schema are optional and custom fields can be included. Because of this, a HEScore Use Case for HPXML is available that specifies the specific HPXML fields required to run this workflow. The [HPXML HEScore Use Case](https://github.com/NREL/OpenStudio-HEScore/blob/master/measures/HEScoreRuleset/resources/HESvalidator.rb) is defined as a set of conditional XPath expressions.

It is expected that the HEScore API will be providing HPXML files that are consistent with these requirements.
