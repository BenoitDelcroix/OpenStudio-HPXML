# frozen_string_literal: true

class HEScoreRuleset
  def self.apply_ruleset(json, weather)
    # Create new HPXML object
    new_hpxml = HPXML.new
    new_hpxml.header.xml_type = nil  # FIXME: does json contain this information?
    new_hpxml.header.xml_generated_by = 'OpenStudio-HEScore'
    new_hpxml.header.transaction = 'create'  # FIXME: does json contain this information?
    new_hpxml.header.building_id = json['building']['building_id']
    new_hpxml.header.event_type = 'construction-period testing/daily test out'  # FIXME: does json contain this information?

    # BuildingSummary
    set_summary(json, new_hpxml)

    # ClimateAndRiskZones
    set_climate(json, new_hpxml)

    # Enclosure
    set_enclosure_air_infiltration(json, new_hpxml)
    set_enclosure_roofs(json, new_hpxml)
    set_enclosure_rim_joists(json, new_hpxml)
    set_enclosure_walls(json, new_hpxml)
    set_enclosure_foundation_walls(json, new_hpxml)
    set_enclosure_framefloors(json, new_hpxml)
    set_enclosure_slabs(json, new_hpxml)
    set_enclosure_windows(json, new_hpxml)
    set_enclosure_skylights(json, new_hpxml)
    set_enclosure_doors(json, new_hpxml)

    # # Systems
    # set_systems_hvac(json, new_hpxml)
    set_systems_mechanical_ventilation(json, new_hpxml)
    set_systems_water_heater(json, new_hpxml)
    set_systems_water_heating_use(json, new_hpxml)
    set_systems_photovoltaics(json, new_hpxml)

    # # Appliances
    # set_appliances_clothes_washer(json, new_hpxml)
    # set_appliances_clothes_dryer(json, new_hpxml)
    # set_appliances_dishwasher(json, new_hpxml)
    # set_appliances_refrigerator(json, new_hpxml)
    # set_appliances_cooking_range_oven(json, new_hpxml)

    # # Lighting
    # set_lighting(json, new_hpxml)
    # set_ceiling_fans(json, new_hpxml)

    # # MiscLoads
    # set_misc_plug_loads(json, new_hpxml)
    # set_misc_television(json, new_hpxml)

    # # Prevent downstream errors in OS-HPXML
    # adjust_floor_areas(new_hpxml)

    # HPXMLDefaults.apply(new_hpxml, Constants.ERIVersions[-1], weather)

    return new_hpxml
  end

  def self.set_summary(json, new_hpxml)
    # Get HPXML values
    if json['building']['about']['town_house_walls']
      @bldg_type = HPXML::ResidentialTypeSFA  # FIXME: double-check
    else
      @bldg_type = HPXML::ResidentialTypeSFD
    end
    @bldg_orient = json['building']['about']['orientation']
    @bldg_azimuth = orientation_to_azimuth(@bldg_orient)

    @year_built = json['building']['about']['year_built']
    @nbeds = json['building']['about']['number_bedrooms']
    @cfa = json['building']['about']['conditioned_floor_area'] # ft^2
    @is_townhouse = (@bldg_type == HPXML::ResidentialTypeSFA)
    @fnd_areas = get_foundation_areas(json)
    @ducts = get_ducts_details(json)
    @cfa_basement = @fnd_areas[HPXML::LocationBasementConditioned]
    @cfa_basement = 0 if @cfa_basement.nil?
    @ncfl_ag = json['building']['about']['num_floor_above_grade']  # FIXME: double-check
    @ceil_height = json['building']['about']['floor_to_ceiling_height']  # ft

    # Calculate geometry
    @has_cond_bsmnt = @fnd_areas.key?(HPXML::LocationBasementConditioned)
    @has_uncond_bsmnt = @fnd_areas.key?(HPXML::LocationBasementUnconditioned)
    @ncfl = @ncfl_ag + (@has_cond_bsmnt ? 1 : 0)
    @nfl = @ncfl + (@has_uncond_bsmnt ? 1 : 0)
    @bldg_footprint = (@cfa - @cfa_basement) / @ncfl_ag # ft^2
    @bldg_length_side = (3.0 * @bldg_footprint / 5.0)**0.5 # ft
    @bldg_length_front = (5.0 / 3.0) * @bldg_length_side # ft
    if @is_townhouse
      @bldg_length_front, @bldg_length_side = @bldg_length_side, @bldg_length_front
    end
    @bldg_perimeter = 2.0 * @bldg_length_front + 2.0 * @bldg_length_side # ft
    @roof_angle = 30.0 # deg
    @roof_angle_rad = UnitConversions.convert(@roof_angle, 'deg', 'rad') # radians
    @cvolume = calc_conditioned_volume(json)

    # Neighboring buildings to left/right, 12ft offset, same height as building.
    new_hpxml.neighbor_buildings.add(azimuth: sanitize_azimuth(@bldg_azimuth + 90.0),
                                     distance: 20.0,
                                     height: 12.0)
    new_hpxml.neighbor_buildings.add(azimuth: sanitize_azimuth(@bldg_azimuth - 90.0),
                                     distance: 20.0,
                                     height: 12.0)

    new_hpxml.building_construction.residential_facility_type = @bldg_type
    new_hpxml.building_construction.number_of_conditioned_floors = @ncfl
    new_hpxml.building_construction.number_of_conditioned_floors_above_grade = @ncfl_ag
    new_hpxml.building_construction.number_of_bedrooms = @nbeds
    new_hpxml.building_construction.conditioned_floor_area = @cfa
    new_hpxml.building_construction.conditioned_building_volume = @cvolume
    new_hpxml.building_construction.has_flue_or_chimney = false
  end

  def self.set_climate(json, new_hpxml)
    zipcode = json['building_address']['zip_code']

    zipcode_city = nil
    zipcode_state = nil
    station_name = nil
    station_wmo = nil
    epw_filename = nil
    iecc_zone = nil
    CSV.foreach(File.join(File.dirname(__FILE__), 'zipcodes_wx.csv'), headers: true) do |row|
      next unless row['postal_code'] == zipcode[0..6]

      zipcode_city = row['city']
      zipcode_state = row['state_zipcode']
      station_name = row['name']
      station_wmo = row['nearest_weather_station']
      epw_filename = row['weather_filename']
      iecc_zone = row['iecc_cz']
      break
    end
    fail "Could not lookup weather station for zipcode #{zipcode}." if epw_filename.nil?

    new_hpxml.climate_and_risk_zones.weather_station_id = "#{zipcode_city}_#{zipcode_state}"
    new_hpxml.climate_and_risk_zones.weather_station_name = station_name
    new_hpxml.climate_and_risk_zones.weather_station_wmo = station_wmo
    new_hpxml.climate_and_risk_zones.weather_station_epw_filepath = epw_filename

    @iecc_zone = iecc_zone
  end

  def self.set_enclosure_air_infiltration(json, new_hpxml)
    if not json['building']['about']['blower_door_test'].nil?
      cfm50 = json['building']['about']['envelope_leakage']
      if json['building']['about']['air_sealing_present'] == true
        desc = HPXML::LeakinessTight
      else
        desc = HPXML::LeakinessAverage
      end

      # Convert to ACH50
      if not cfm50.nil?
        ach50 = cfm50 * 60.0 / @cvolume
      else
        ach50 = calc_ach50(@ncfl_ag, @cfa, @ceil_height, @cvolume, desc, @year_built, @iecc_zone, @fnd_areas, @ducts)
      end

      new_hpxml.air_infiltration_measurements.add(id: 'hescore_blower_door_test',
                                                  house_pressure: 50,
                                                  unit_of_measure: HPXML::UnitsACH,
                                                  air_leakage: ach50)
    end
  end

  def self.set_enclosure_roofs(json, new_hpxml)
    json['building']['zone']['zone_roof'].each do |orig_roof|
      attic_location = {'vented_attic' => HPXML::LocationAtticVented,
                        'cond_attic' => HPXML::LocationLivingSpace,
                        'cath_ceiling' => HPXML::LocationLivingSpace}[orig_roof['roof_type']]
      # Roof: Two surfaces per HES zone_roof
      roof_area = orig_roof['roof_area']
      roof_solar_abs = get_roof_solar_absorptance(orig_roof['roof_color'])
      roof_r = get_roof_effective_r_from_doe2code(orig_roof['roof_assembly_code'])
      if @is_townhouse
        roof_azimuths = [@bldg_azimuth + 90, @bldg_azimuth + 270]
      else
        roof_azimuths = [@bldg_azimuth, @bldg_azimuth + 180]
      end
      has_radiant_barrier = false
      if orig_roof['roof_assembly_code'][2,2] == 'rb'
        has_radiant_barrier = true
      end
      roof_azimuths.each_with_index do |roof_azimuth, idx|
        new_hpxml.roofs.add(id: "#{orig_roof['roof_name']}_#{idx}",
                            interior_adjacent_to: attic_location,
                            area: roof_area / 2.0,
                            azimuth: sanitize_azimuth(roof_azimuth),
                            solar_absorptance: roof_solar_abs,
                            emittance: 0.9,
                            pitch: Math.tan(@roof_angle_rad) * 12,
                            radiant_barrier: has_radiant_barrier,
                            radiant_barrier_grade: 1,  # FIXME: json doesn't seem to provide radiant barrier grade
                            insulation_assembly_r_value: roof_r)
      end
    end
  end

  def self.set_enclosure_rim_joists(json, new_hpxml)
    # No rim joists
  end

  def self.set_enclosure_walls(json, new_hpxml)
    # Above-grade walls
    json['building']['zone']['zone_wall'].each do |orig_wall|
      wall_area = nil
      if ['front', 'back'].include? orig_wall['side']
        wall_area = @ceil_height * @bldg_length_front * @ncfl_ag
      else
        wall_area = @ceil_height * @bldg_length_side * @ncfl_ag
      end
      wall_r = get_wall_effective_r_from_doe2code(orig_wall['wall_assembly_code'])
      new_hpxml.walls.add(id: "#{orig_wall['side']}_wall",
                          exterior_adjacent_to: HPXML::LocationOutside,
                          interior_adjacent_to: HPXML::LocationLivingSpace,
                          wall_type: $wall_type_map[orig_wall['wall_assembly_code'][2,2]],
                          area: wall_area,
                          azimuth: sanitize_azimuth(wall_orientation_to_azimuth(orig_wall['side'])),
                          solar_absorptance: 0.75,
                          emittance: 0.9,
                          insulation_assembly_r_value: wall_r)
    end
  end

  def self.set_enclosure_foundation_walls(json, new_hpxml)
    json['building']['zone']['zone_floor'].each do |orig_foundation|
      fnd_location = {'uncond_basement' => HPXML::LocationBasementUnconditioned,
                      'cond_basement' => HPXML::LocationBasementConditioned,
                      'vented_crawl' => HPXML::LocationCrawlspaceVented,
                      'unvented_crawl' => HPXML::LocationCrawlspaceUnvented,
                      'slab_on_grade' => HPXML::LocationLivingSpace}[orig_foundation['foundation_type']]
      fnd_area = orig_foundation['floor_area']
      next unless [HPXML::LocationBasementUnconditioned, HPXML::LocationBasementConditioned, HPXML::LocationCrawlspaceVented, HPXML::LocationCrawlspaceUnvented].include? fnd_location
      
      if [HPXML::LocationBasementUnconditioned, HPXML::LocationBasementConditioned].include? fnd_location
        fndwall_height = 8.0
      else
        fndwall_height = 2.5
      end

      new_hpxml.foundation_walls.add(id: "#{orig_foundation['floor_name']}_foundation_wall",
                                     exterior_adjacent_to: HPXML::LocationGround,
                                     interior_adjacent_to: fnd_location,
                                     height: fndwall_height,
                                     area: fndwall_height * get_foundation_perimeter(json, orig_foundation),
                                     thickness: 10,
                                     depth_below_grade: fndwall_height - 1.0,
                                     insulation_interior_r_value: 0,
                                     insulation_interior_distance_to_top: 0,
                                     insulation_interior_distance_to_bottom: 0,
                                     insulation_exterior_r_value: Float(orig_foundation['foundation_insulation_level']),
                                     insulation_exterior_distance_to_top: 0,
                                     insulation_exterior_distance_to_bottom: fndwall_height)
    end
  end

  def self.set_enclosure_framefloors(json, new_hpxml)
    # Floors above foundation
    json['building']['zone']['zone_floor'].each do |orig_foundation|
      fnd_location = {'uncond_basement' => HPXML::LocationBasementUnconditioned,
                      'cond_basement' => HPXML::LocationBasementConditioned,
                      'vented_crawl' => HPXML::LocationCrawlspaceVented,
                      'unvented_crawl' => HPXML::LocationCrawlspaceUnvented,
                      'slab_on_grade' => HPXML::LocationLivingSpace}[orig_foundation['foundation_type']]
      next unless [HPXML::LocationBasementUnconditioned, HPXML::LocationCrawlspaceVented, HPXML::LocationCrawlspaceUnvented].include? fnd_location

      framefloor_r = get_floor_effective_r_from_doe2code(orig_foundation['floor_assembly_code'])

      new_hpxml.frame_floors.add(id: "framefloor_adjacent_to_#{orig_foundation['foundation_type']}",
                                 exterior_adjacent_to: fnd_location,
                                 interior_adjacent_to: HPXML::LocationLivingSpace,
                                 area: orig_foundation['floor_area'],
                                 insulation_assembly_r_value: framefloor_r)
    end

    # Floors below attic
    json['building']['zone']['zone_roof'].each do |orig_attic|
      attic_location = {'vented_attic' => HPXML::LocationAtticVented,
                        'cond_attic' => HPXML::LocationLivingSpace,
                        'cath_ceiling' => HPXML::LocationLivingSpace}[orig_attic['roof_type']]
      next unless attic_location == HPXML::LocationAtticVented

      framefloor_r = get_ceiling_effective_r_from_doe2code(orig_attic['ceiling_assembly_code'])
      framefloor_area = orig_attic['roof_area'] * Math.tan(@roof_angle_rad)

      new_hpxml.frame_floors.add(id: "framefloor_adjacent_to_#{orig_attic['roof_type']}",
                                 exterior_adjacent_to: attic_location,
                                 interior_adjacent_to: HPXML::LocationLivingSpace,
                                 area: framefloor_area,  # FIXME: double-check
                                 insulation_assembly_r_value: framefloor_r)
    end
  end

  def self.set_enclosure_slabs(json, new_hpxml)
    json['building']['zone']['zone_floor'].each_with_index do |orig_foundation, idx|
      fnd_location = {'uncond_basement' => HPXML::LocationBasementUnconditioned,
                      'cond_basement' => HPXML::LocationBasementConditioned,
                      'vented_crawl' => HPXML::LocationCrawlspaceVented,
                      'unvented_crawl' => HPXML::LocationCrawlspaceUnvented,
                      'slab_on_grade' => HPXML::LocationLivingSpace}[orig_foundation['foundation_type']]
      fnd_type = orig_foundation['foundation_type']
      fnd_area = orig_foundation['floor_area']

      # Slab
      slab_id = nil
      slab_area = nil
      slab_thickness = nil
      slab_depth_below_grade = nil
      slab_perimeter_insulation_r_value = nil
      if fnd_type == 'slab_on_grade'
        slab_id = "slab_on_grade_#{idx}"
        slab_area = orig_foundation['floor_area']
        slab_perimeter_insulation_r_value = orig_foundation['foundation_insulation_level']
        slab_depth_below_grade = 0
        slab_thickness = 4
      elsif ['uncond_basement', 'cond_basement', 'vented_crawl', 'unvented_crawl'].include? fnd_type
        slab_id = "#{fnd_type}_slab_#{idx}"
        slab_area = orig_foundation['floor_area']
        slab_perimeter_insulation_r_value = 0
        if ['uncond_basement', 'cond_basement'].include? fnd_type
          slab_thickness = 4
        else
          slab_thickness = 0
        end
      else
        fail "Unexpected foundation type: #{fnd_type}"
      end

      new_hpxml.slabs.add(id: slab_id,
                          interior_adjacent_to: fnd_location,
                          area: slab_area,
                          thickness: slab_thickness,
                          exposed_perimeter: get_foundation_perimeter(json, orig_foundation),
                          perimeter_insulation_depth: 2,
                          under_slab_insulation_width: 0,
                          depth_below_grade: slab_depth_below_grade,
                          carpet_fraction: 1.0,
                          carpet_r_value: 2.1,
                          perimeter_insulation_r_value: slab_perimeter_insulation_r_value,
                          under_slab_insulation_r_value: 0)
    end
  end

  def self.set_enclosure_windows(json, new_hpxml)
    json['building']['zone']['zone_wall'].each do |orig_wall|
      next unless orig_wall.key?('zone_window')

      orig_window = orig_wall['zone_window']
      ufactor = orig_window['window_u_value']
      shgc = orig_window['window_shgc']
      if ufactor.nil?
        ufactor, shgc = get_window_skylight_ufactor_shgc_from_doe2code(orig_window['window_code'])
      end

      interior_shading_factor_summer, interior_shading_factor_winter = Constructions.get_default_interior_shading_factors()
      exterior_shading_factor_summer = 1.0
      exterior_shading_factor_winter = 1.0
      # FIXME: Can one specify solar screens in hescore json?
      # if orig_window.exterior_shading_type == 'solar screens'
      #   # Summer only, total shading factor reduced to 0.29
      #   exterior_shading_factor_summer = 0.29 / interior_shading_factor_summer # Overall shading factor is interior multiplied by exterior
      # end

      # Add one HPXML window per side of the house with only the overhangs from the roof.
      new_hpxml.windows.add(id: "#{orig_wall['side']}_window",
                            area: orig_window['window_area'],
                            azimuth: sanitize_azimuth(wall_orientation_to_azimuth(orig_wall['side'])),
                            ufactor: ufactor,
                            shgc: shgc,
                            overhangs_depth: 1.0,
                            overhangs_distance_to_top_of_window: 0.0,
                            overhangs_distance_to_bottom_of_window: @ceil_height * @ncfl_ag,
                            wall_idref: "#{orig_wall['side']}_wall",
                            interior_shading_factor_summer: interior_shading_factor_summer,
                            interior_shading_factor_winter: interior_shading_factor_winter,
                            exterior_shading_factor_summer: exterior_shading_factor_summer,
                            exterior_shading_factor_winter: exterior_shading_factor_winter)
    end 
  end

  def self.set_enclosure_skylights(json, new_hpxml)
    json['building']['zone']['zone_roof'].each do |orig_roof|
      next unless orig_roof.key?('zone_skylight')

      orig_skylight = orig_roof['zone_skylight']
      ufactor = orig_skylight['skylight_u_value']
      shgc = orig_skylight['skylight_shgc']
      if ufactor.nil?
        ufactor, shgc = get_window_skylight_ufactor_shgc_from_doe2code(orig_skylight['skylight_code'])
      end

      interior_shading_factor_summer = 1.0
      interior_shading_factor_winter = 1.0
      exterior_shading_factor_summer = 1.0
      exterior_shading_factor_winter = 1.0
      # FIXME: Can one specify solar screens in hescore json?
      # if orig_skylight.exterior_shading_type == 'solar screens'
      #   # Year-round, total shading factor reduced to 0.29
      #   exterior_shading_factor_summer = 0.29
      #   exterior_shading_factor_winter = 0.29
      # end

      if @is_townhouse
        roof_azimuths = [@bldg_azimuth + 90, @bldg_azimuth + 270]
      else
        roof_azimuths = [@bldg_azimuth, @bldg_azimuth + 180]
      end
      roof_azimuths.each_with_index do |roof_azimuth, idx|  # FIXME: double-check
        skylight_area = orig_skylight.area / 2.0
        new_hpxml.skylights.add(id: "#{orig_roof['roof_name']}_#{idx}_skylight",
                                area: skylight_area,
                                azimuth: roof_azimuth,
                                ufactor: ufactor,
                                shgc: shgc,
                                roof_idref: "#{orig_roof['roof_name']}_#{idx}",
                                interior_shading_factor_summer: interior_shading_factor_summer,
                                interior_shading_factor_winter: interior_shading_factor_winter,
                                exterior_shading_factor_summer: exterior_shading_factor_summer,
                                exterior_shading_factor_winter: exterior_shading_factor_winter)
      end
    end
  end

  def self.set_enclosure_doors(json, new_hpxml)
    front_wall = nil
    json['building']['zone']['zone_wall'].each do |orig_wall|
      next if orig_wall['side'] != 'front'

      front_wall = orig_wall
    end
    fail 'Could not find front wall.' if front_wall.nil?

    new_hpxml.doors.add(id: 'Door',
                        wall_idref: "#{front_wall['side']}_wall",
                        area: 40,
                        azimuth: orientation_to_azimuth(@bldg_orient),
                        r_value: 1.0 / 0.51)
  end

  def self.set_systems_hvac(json, new_hpxml)
    additional_hydronic_ids = []

    # HeatingSystem
    json.heating_systems.each do |orig_heating|
      distribution_system_idref = orig_heating.distribution_system_idref
      heating_system_type = orig_heating.heating_system_type
      heating_system_fuel = orig_heating.heating_system_fuel
      heating_efficiency_afue = orig_heating.heating_efficiency_afue
      heating_efficiency_percent = orig_heating.heating_efficiency_percent
      year_installed = orig_heating.year_installed
      energy_star = (orig_heating.third_party_certification == HPXML::CertificationEnergyStar)
      fraction_heat_load_served = orig_heating.fraction_heat_load_served

      # Need to create hydronic distribution system?
      if (heating_system_type == HPXML::HVACTypeBoiler) && distribution_system_idref.nil?
        distribution_system_idref = orig_heating.id + '_dist'
        additional_hydronic_ids << distribution_system_idref
      end

      if [HPXML::HVACTypeFurnace, HPXML::HVACTypeWallFurnace].include? heating_system_type
        if not heating_efficiency_afue.nil?
          # Do nothing, we already have the AFUE
        elsif heating_system_fuel == HPXML::FuelTypeElectricity
          heating_efficiency_afue = 0.98
        elsif energy_star && (heating_system_type == HPXML::HVACTypeFurnace)
          heating_efficiency_afue = lookup_hvac_efficiency(year_installed,
                                                           heating_system_type,
                                                           heating_system_fuel,
                                                           'AFUE',
                                                           'energy_star',
                                                           json.header.state_code)
        elsif not year_installed.nil?
          heating_efficiency_afue = lookup_hvac_efficiency(year_installed,
                                                           heating_system_type,
                                                           heating_system_fuel,
                                                           'AFUE')
        end

      elsif heating_system_type == HPXML::HVACTypeBoiler
        if not heating_efficiency_afue.nil?
          # Do nothing, we already have the AFUE
        elsif heating_system_fuel == HPXML::FuelTypeElectricity
          heating_efficiency_afue = 0.98
        elsif energy_star
          heating_efficiency_afue = lookup_hvac_efficiency(year_installed,
                                                           heating_system_type,
                                                           heating_system_fuel,
                                                           'AFUE',
                                                           'energy_star')
        elsif not year_installed.nil?
          heating_efficiency_afue = lookup_hvac_efficiency(year_installed,
                                                           heating_system_type,
                                                           heating_system_fuel,
                                                           'AFUE')
        end

      elsif heating_system_type == HPXML::HVACTypeElectricResistance
        if heating_efficiency_percent.nil?
          heating_efficiency_percent = 0.98
        end

      elsif heating_system_type == HPXML::HVACTypeStove
        if not heating_efficiency_percent.nil?
          # Do nothing, we already have the heating efficiency percent
        elsif heating_system_fuel == HPXML::FuelTypeWoodCord
          heating_efficiency_percent = 0.60
        elsif heating_system_fuel == HPXML::FuelTypeWoodPellets
          heating_efficiency_percent = 0.78
        end
      end

      new_hpxml.heating_systems.add(id: orig_heating.id,
                                    distribution_system_idref: distribution_system_idref,
                                    heating_system_type: heating_system_type,
                                    heating_system_fuel: heating_system_fuel,
                                    heating_efficiency_afue: heating_efficiency_afue,
                                    heating_efficiency_percent: heating_efficiency_percent,
                                    fraction_heat_load_served: fraction_heat_load_served)
    end

    # CoolingSystem
    json.cooling_systems.each do |orig_cooling|
      distribution_system_idref = orig_cooling.distribution_system_idref
      cooling_system_type = orig_cooling.cooling_system_type
      cooling_system_fuel = HPXML::FuelTypeElectricity
      cooling_efficiency_seer = orig_cooling.cooling_efficiency_seer
      cooling_efficiency_eer = orig_cooling.cooling_efficiency_eer
      year_installed = orig_cooling.year_installed
      energy_star = (orig_cooling.third_party_certification == HPXML::CertificationEnergyStar)
      fraction_cool_load_served = orig_cooling.fraction_cool_load_served

      if cooling_system_type == HPXML::HVACTypeCentralAirConditioner
        if not cooling_efficiency_seer.nil?
          # Do nothing, we already have the SEER
        elsif energy_star
          cooling_efficiency_seer = lookup_hvac_efficiency(year_installed,
                                                           cooling_system_type,
                                                           cooling_system_fuel,
                                                           'SEER',
                                                           'energy_star')
        elsif not year_installed.nil?
          cooling_efficiency_seer = lookup_hvac_efficiency(year_installed,
                                                           cooling_system_type,
                                                           cooling_system_fuel,
                                                           'SEER')
        end

      elsif cooling_system_type == HPXML::HVACTypeRoomAirConditioner
        if not cooling_efficiency_eer.nil?
          # Do nothing, we already have the EER
        elsif energy_star
          cooling_efficiency_eer = lookup_hvac_efficiency(year_installed,
                                                          cooling_system_type,
                                                          cooling_system_fuel,
                                                          'EER',
                                                          'energy_star')
        elsif not year_installed.nil?
          cooling_efficiency_eer = lookup_hvac_efficiency(year_installed,
                                                          cooling_system_type,
                                                          cooling_system_fuel,
                                                          'EER')
        end
      end

      new_hpxml.cooling_systems.add(id: orig_cooling.id,
                                    distribution_system_idref: distribution_system_idref,
                                    cooling_system_type: cooling_system_type,
                                    cooling_system_fuel: cooling_system_fuel,
                                    fraction_cool_load_served: fraction_cool_load_served,
                                    cooling_efficiency_seer: cooling_efficiency_seer,
                                    cooling_efficiency_eer: cooling_efficiency_eer)
    end

    # HeatPump
    json.heat_pumps.each do |orig_hp|
      heat_pump_fuel = HPXML::FuelTypeElectricity
      backup_heating_fuel = HPXML::FuelTypeElectricity
      backup_heating_efficiency_percent = 1.0
      heat_pump_type = orig_hp.heat_pump_type
      cooling_efficiency_seer = orig_hp.cooling_efficiency_seer
      cooling_efficiency_eer = orig_hp.cooling_efficiency_eer
      heating_efficiency_hspf = orig_hp.heating_efficiency_hspf
      heating_efficiency_cop = orig_hp.heating_efficiency_cop
      distribution_system_idref = orig_hp.distribution_system_idref
      year_installed = orig_hp.year_installed
      energy_star = (orig_hp.third_party_certification == HPXML::CertificationEnergyStar)
      fraction_cool_load_served = orig_hp.fraction_cool_load_served
      fraction_heat_load_served = orig_hp.fraction_heat_load_served

      if [HPXML::HVACTypeHeatPumpAirToAir, HPXML::HVACTypeHeatPumpMiniSplit].include? heat_pump_type
        if not cooling_efficiency_seer.nil?
          # Do nothing, we have the SEER
        elsif energy_star
          cooling_efficiency_seer = lookup_hvac_efficiency(year_installed,
                                                           heat_pump_type,
                                                           heat_pump_fuel,
                                                           'SEER',
                                                           'energy_star')
        elsif not year_installed.nil?
          cooling_efficiency_seer = lookup_hvac_efficiency(year_installed,
                                                           heat_pump_type,
                                                           heat_pump_fuel,
                                                           'SEER')
        end
        if not heating_efficiency_hspf.nil?
          # Do nothing, we have the HSPF
        elsif energy_star
          heating_efficiency_hspf = lookup_hvac_efficiency(year_installed,
                                                           heat_pump_type,
                                                           heat_pump_fuel,
                                                           'HSPF',
                                                           'energy_star')
        elsif not year_installed.nil?
          heating_efficiency_hspf = lookup_hvac_efficiency(year_installed,
                                                           heat_pump_type,
                                                           heat_pump_fuel,
                                                           'HSPF')
        end
      end

      # If heat pump has no cooling/heating load served, assign arbitrary value for cooling/heating efficiency value
      if (fraction_cool_load_served == 0) && cooling_efficiency_seer.nil? && cooling_efficiency_eer.nil?
        if heat_pump_type == HPXML::HVACTypeHeatPumpGroundToAir
          cooling_efficiency_eer = 16.6
        else
          cooling_efficiency_seer = 13.0
        end
      end
      if (fraction_heat_load_served == 0) && heating_efficiency_hspf.nil? && heating_efficiency_cop.nil?
        if heat_pump_type == HPXML::HVACTypeHeatPumpGroundToAir
          heating_efficiency_cop = 3.6
        else
          heating_efficiency_hspf = 7.7
        end
      end

      new_hpxml.heat_pumps.add(id: orig_hp.id,
                               distribution_system_idref: distribution_system_idref,
                               heat_pump_type: heat_pump_type,
                               heat_pump_fuel: heat_pump_fuel,
                               backup_heating_fuel: backup_heating_fuel,
                               backup_heating_efficiency_percent: backup_heating_efficiency_percent,
                               fraction_heat_load_served: fraction_heat_load_served,
                               fraction_cool_load_served: fraction_cool_load_served,
                               cooling_efficiency_seer: cooling_efficiency_seer,
                               cooling_efficiency_eer: cooling_efficiency_eer,
                               heating_efficiency_hspf: heating_efficiency_hspf,
                               heating_efficiency_cop: heating_efficiency_cop)
    end

    # HVACControl
    control_type = HPXML::HVACControlTypeManual
    htg_sp, htg_setback_sp, htg_setback_hrs_per_week, htg_setback_start_hr = HVAC.get_default_heating_setpoint(control_type)
    clg_sp, clg_setup_sp, clg_setup_hrs_per_week, clg_setup_start_hr = HVAC.get_default_cooling_setpoint(control_type)
    new_hpxml.hvac_controls.add(id: 'HVACControl',
                                control_type: control_type,
                                heating_setpoint_temp: htg_sp,
                                cooling_setpoint_temp: clg_sp)

    # HVACDistribution
    json.hvac_distributions.each do |orig_dist|
      new_hpxml.hvac_distributions.add(id: orig_dist.id,
                                       distribution_system_type: HPXML::HVACDistributionTypeAir,
                                       air_type: HPXML::AirTypeRegularVelocity)

      hvac_fraction = get_hvac_fraction(json, orig_dist.id)
      new_hpxml.hvac_distributions[-1].conditioned_floor_area_served = hvac_fraction * @cfa

      frac_inside = 0.0
      orig_dist.ducts.each do |orig_duct|
        next unless orig_duct.duct_location == HPXML::LocationLivingSpace

        frac_inside += orig_duct.duct_fraction_area
      end

      sealed = orig_dist.duct_system_sealed
      lto_s, lto_r, uncond_area_s, uncond_area_r = calc_duct_values(@ncfl_ag, @cfa, sealed, frac_inside)

      # Supply duct leakage to the outside
      new_hpxml.hvac_distributions[-1].duct_leakage_measurements.add(duct_type: HPXML::DuctTypeSupply,
                                                                     duct_leakage_units: HPXML::UnitsPercent,
                                                                     duct_leakage_value: lto_s,
                                                                     duct_leakage_total_or_to_outside: HPXML::DuctLeakageToOutside)

      # Return duct leakage to the outside
      new_hpxml.hvac_distributions[-1].duct_leakage_measurements.add(duct_type: HPXML::DuctTypeReturn,
                                                                     duct_leakage_units: HPXML::UnitsPercent,
                                                                     duct_leakage_value: lto_r,
                                                                     duct_leakage_total_or_to_outside: HPXML::DuctLeakageToOutside)

      orig_dist.ducts.each do |orig_duct|
        next if orig_duct.duct_location == HPXML::LocationLivingSpace

        if orig_duct.duct_location == HPXML::LocationAtticUnconditioned
          orig_duct.duct_location = HPXML::LocationAtticVented
        end

        if orig_duct.duct_insulation_material == HPXML::DuctInsulationMaterialUnknown
          duct_rvalue = 6
        elsif orig_duct.duct_insulation_material == HPXML::DuctInsulationMaterialNone
          duct_rvalue = 0
        else
          fail "Unexpected duct insulation material '#{orig_duct.duct_insulation_material}'."
        end

        supply_duct_surface_area = uncond_area_s * orig_duct.duct_fraction_area / (1.0 - frac_inside)
        return_duct_surface_area = uncond_area_r * orig_duct.duct_fraction_area / (1.0 - frac_inside)

        # Supply duct
        new_hpxml.hvac_distributions[-1].ducts.add(duct_type: HPXML::DuctTypeSupply,
                                                   duct_insulation_r_value: duct_rvalue,
                                                   duct_location: orig_duct.duct_location,
                                                   duct_surface_area: supply_duct_surface_area)

        # Return duct
        new_hpxml.hvac_distributions[-1].ducts.add(duct_type: HPXML::DuctTypeReturn,
                                                   duct_insulation_r_value: duct_rvalue,
                                                   duct_location: orig_duct.duct_location,
                                                   duct_surface_area: return_duct_surface_area)
      end
    end

    additional_hydronic_ids.each do |hydronic_id|
      new_hpxml.hvac_distributions.add(id: hydronic_id,
                                       distribution_system_type: HPXML::HVACDistributionTypeHydronic,
                                       hydronic_type: HPXML::HydronicTypeBaseboard)
    end
  end

  def self.set_systems_mechanical_ventilation(json, new_hpxml)
    # No mechanical ventilation
  end

  def self.set_systems_water_heater(json, new_hpxml)
    return unless json['building']['systems'].key? ('domestic_hot_water')
    
    orig_water_heater = json['building']['systems']['domestic_hot_water']
    energy_factor = orig_water_heater['energy_factor']
    fuel_type = {
      'electric' => HPXML::FuelTypeElectricity,
      'natural_gas' => HPXML::FuelTypeNaturalGas,
      'lpg' => HPXML::FuelTypePropane,
      'fuel_oil' => HPXML::FuelTypeOil}[orig_water_heater['fuel_primary']]
    water_heater_type = {
      'storage' => HPXML::WaterHeaterTypeStorage,
      'indirect' => HPXML::WaterHeaterTypeCombiStorage,
      'tankless' => HPXML::WaterHeaterTypeTankless,
      'tankless_coil' => HPXML::WaterHeaterTypeCombiTankless,
      'heat_pump' => HPXML::WaterHeaterTypeHeatPump}[orig_water_heater['type']]
    year_installed = orig_water_heater['year']
    # FIXME: can one specify third party certification in hescore json?
    # energy_star = (orig_water_heater.third_party_certification == HPXML::CertificationEnergyStar)

    if not energy_factor.nil?
      if orig_water_heater['efficiency_method'] == 'uef'
        # Convert to EF
        # FUTURE: Remove this conversion and use UEF directly; requires FHR input/assumption for storage water heaters
        energy_factor = Waterheater.calc_ef_from_uef(orig_water_heater)  # FIXME: Cannot use this function!
      end
      # Do nothing if efficiency method is 'user', we already have the energy factor
    # elsif energy_star  # FIXME: can one specify third party certification in hescore json?
    #   energy_factor = lookup_water_heater_efficiency(year_installed,
    #                                                  fuel_type,
    #                                                  'energy_star')
    elsif not year_installed.nil?
      energy_factor = lookup_water_heater_efficiency(year_installed,
                                                     fuel_type)
    end

    fail 'Water Heater Type must be provided' if water_heater_type.nil?
    # fail 'Electric water heaters must be heat pump water heaters to be Energy Star qualified' if energy_star && (fuel_type == HPXML::FuelTypeElectricity) && (water_heater_type != HPXML::WaterHeaterTypeHeatPump)

    heating_capacity = nil
    if water_heater_type == HPXML::WaterHeaterTypeStorage
      heating_capacity = get_default_water_heater_capacity(fuel_type)
    end
    tank_volume = nil
    if water_heater_type == HPXML::WaterHeaterTypeCombiStorage
      tank_volume = get_default_water_heater_volume(HPXML::FuelTypeElectricity)
    # Set default fuel_type to call function : get_default_water_heater_volume, not passing this input to EP-HPXML
    elsif (water_heater_type != HPXML::WaterHeaterTypeTankless) && (water_heater_type != HPXML::WaterHeaterTypeCombiTankless)
      tank_volume = get_default_water_heater_volume(fuel_type)
    end

    # Water heater location
    if @has_cond_bsmnt
      water_heater_location = HPXML::LocationBasementConditioned
    elsif @has_uncond_bsmnt
      water_heater_location = HPXML::LocationBasementUnconditioned
    else
      water_heater_location = HPXML::LocationLivingSpace
    end

    new_hpxml.water_heating_systems.add(id: 'WaterHeater',
                                        fuel_type: fuel_type,
                                        water_heater_type: water_heater_type,
                                        location: water_heater_location,
                                        tank_volume: tank_volume,
                                        fraction_dhw_load_served: 1.0,
                                        heating_capacity: heating_capacity,
                                        energy_factor: energy_factor,
                                        related_hvac_idref: nil)  #orig_water_heater.related_hvac_idref)  # FIXME: Need to discuss it with Scott
  end

  def self.set_systems_water_heating_use(json, new_hpxml)
    new_hpxml.hot_water_distributions.add(id: 'HotWaterDistribution',
                                          system_type: HPXML::DHWDistTypeStandard,
                                          pipe_r_value: 0)

    new_hpxml.water_fixtures.add(id: 'ShowerHead',
                                 water_fixture_type: HPXML::WaterFixtureTypeShowerhead,
                                 low_flow: false)
  end

  def self.set_systems_photovoltaics(json, new_hpxml)
    return unless json['building']['systems'].key?('generation')
    return unless json['building']['systems']['generation'].key?('solar_electric')

    orig_pv_system = json['building']['systems']['generation']['solar_electric']

    max_power_output = orig_pv_system['system_capacity']
    if max_power_output.nil?
      # Estimate from year and # modules
      module_power = PV.calc_module_power_from_year(orig_pv_system['year']) # W/panel
      max_power_output = orig_pv_system['num_panels'] * module_power
    end

    new_hpxml.pv_systems.add(id: 'PVSystem',
                             location: HPXML::LocationRoof,
                             module_type: HPXML::PVModuleTypeStandard,
                             tracking: HPXML::PVTrackingTypeFixed,
                             array_azimuth: orientation_to_azimuth(orig_pv_system['array_azimuth']),
                             array_tilt: @roof_angle,
                             max_power_output: max_power_output,
                             year_modules_manufactured: orig_pv_system['year'])
  end

  def self.set_appliances_clothes_washer(json, new_hpxml)
    new_hpxml.clothes_washers.add(id: 'ClothesWasher')
  end

  def self.set_appliances_clothes_dryer(json, new_hpxml)
    new_hpxml.clothes_dryers.add(id: 'ClothesDryer',
                                 fuel_type: HPXML::FuelTypeElectricity,
                                 is_vented: true,
                                 vented_flow_rate: 0.0)
  end

  def self.set_appliances_dishwasher(json, new_hpxml)
    new_hpxml.dishwashers.add(id: 'Dishwasher')
  end

  def self.set_appliances_refrigerator(json, new_hpxml)
    new_hpxml.refrigerators.add(id: 'Refrigerator')
  end

  def self.set_appliances_cooking_range_oven(json, new_hpxml)
    new_hpxml.cooking_ranges.add(id: 'CookingRange',
                                 fuel_type: HPXML::FuelTypeElectricity)

    new_hpxml.ovens.add(id: 'Oven')
  end

  def self.set_lighting(json, new_hpxml)
    ltg_fracs = Lighting.get_default_fractions()
    ltg_fracs.each_with_index do |(key, fraction), i|
      location, lighting_type = key
      new_hpxml.lighting_groups.add(id: "LightingGroup#{i + 1}",
                                    location: location,
                                    fraction_of_units_in_location: fraction,
                                    lighting_type: lighting_type)
    end
  end

  def self.set_ceiling_fans(json, new_hpxml)
    # No ceiling fans
  end

  def self.set_misc_plug_loads(json, new_hpxml)
    new_hpxml.plug_loads.add(id: 'PlugLoadOther',
                             plug_load_type: HPXML::PlugLoadTypeOther)
  end

  def self.set_misc_television(json, new_hpxml)
    new_hpxml.plug_loads.add(id: 'PlugLoadTV',
                             plug_load_type: HPXML::PlugLoadTypeTelevision)
  end

  def self.adjust_floor_areas(new_hpxml)
    # Gather floors/slabs adjacent to conditioned space
    conditioned_floors = []
    new_hpxml.frame_floors.each do |frame_floor|
      next unless frame_floor.is_floor
      next unless [HPXML::LocationLivingSpace, HPXML::LocationBasementConditioned].include?(frame_floor.interior_adjacent_to) ||
                  [HPXML::LocationLivingSpace, HPXML::LocationBasementConditioned].include?(frame_floor.exterior_adjacent_to)

      conditioned_floors << frame_floor
    end
    new_hpxml.slabs.each do |slab|
      next unless [HPXML::LocationLivingSpace, HPXML::LocationBasementConditioned].include? slab.interior_adjacent_to

      conditioned_floors << slab
    end

    # Check if the sum of conditioned floors' area is greater than CFA.
    # If so, reduce floor areas. Note that the HES API already restricts
    # these two areas to being close, so any adjustments will be small.
    sum_cfa = conditioned_floors.map { |f| f.area }.sum
    if sum_cfa > @cfa
      conditioned_floors.each do |floor|
        floor.area *= @cfa / sum_cfa
      end
    end
  end

  def self.get_foundation_perimeter(json, foundation)
    n_foundations = json['building']['zone']['zone_floor'].size
    if n_foundations == 1
      return @bldg_perimeter
    elsif n_foundations == 2
      fnd_area = foundation['floor_area']
      long_side = [@bldg_length_front, @bldg_length_side].max
      short_side = [@bldg_length_front, @bldg_length_side].min
      total_foundation_area = 0
      json['building']['zone']['zone_floor'].each do |a_foundation|
        total_foundation_area += a_foundation['floor_area']
      end
      fnd_frac = fnd_area / total_foundation_area
      return short_side + 2 * long_side * fnd_frac
    else
      fail 'Only one or two foundations is allowed.'
    end
  end
end

def lookup_hvac_efficiency(year, hvac_type, fuel_type, units, performance_id = 'shipment_weighted', state_code = nil)
  year = 0 if year.nil?

  type_id = { HPXML::HVACTypeCentralAirConditioner => 'split_dx',
              HPXML::HVACTypeRoomAirConditioner => 'packaged_dx',
              HPXML::HVACTypeHeatPumpAirToAir => 'heat_pump',
              HPXML::HVACTypeHeatPumpMiniSplit => 'mini_split',
              HPXML::HVACTypeFurnace => 'central_furnace',
              HPXML::HVACTypeWallFurnace => 'wall_furnace',
              HPXML::HVACTypeBoiler => 'boiler' }[hvac_type]
  fail "Unexpected hvac_type #{hvac_type}." if type_id.nil?

  fuel_primary_id = hpxml_to_hescore_fuel(fuel_type)
  fail "Unexpected fuel_type #{fuel_type}." if fuel_primary_id.nil?

  metric_id = units.downcase

  fail "Invalid performance_id for HVAC lookup #{performance_id}." if not ['shipment_weighted', 'energy_star'].include?(performance_id)

  region_id = nil
  if (performance_id == 'energy_star') && (type_id == 'central_furnace') && ['lpg', 'natural_gas'].include?(fuel_primary_id)
    fail 'state_code required for Energy Star central furnaces' if state_code.nil?

    CSV.foreach(File.join(File.dirname(__FILE__), 'lu_es_furnace_region.csv'), headers: true) do |row|
      next unless row['state_code'] == state_code

      region_id = row['furnace_region']
      break
    end
    fail "Could not lookup Energy Star furnace region for state #{state_code}." if region_id.nil?
  end

  value = nil
  lookup_year = 0
  CSV.foreach(File.join(File.dirname(__FILE__), 'lu_hvac_equipment_efficiency.csv'), headers: true) do |row|
    next unless row['performance_id'] == performance_id
    next unless row['type_id'] == type_id
    next unless row['fuel_primary_id'] == fuel_primary_id
    next unless row['metric_id'] == metric_id
    next unless row['region_id'] == region_id

    row_year = Integer(row['year'])
    if (row_year - year).abs <= (lookup_year - year).abs
      lookup_year = row_year
      value = Float(row['value'])
    end
  end
  fail 'Could not lookup default HVAC efficiency.' if value.nil?

  return value
end

def lookup_water_heater_efficiency(year, fuel_type, performance_id = 'shipment_weighted')
  year = 0 if year.nil?

  fuel_primary_id = hpxml_to_hescore_fuel(fuel_type)
  fail "Unexpected fuel_type #{fuel_type}." if fuel_primary_id.nil?

  fail "Invalid performance_id for water heater lookup #{performance_id}." if not ['shipment_weighted', 'energy_star'].include?(performance_id)

  value = nil
  lookup_year = 0
  CSV.foreach(File.join(File.dirname(__FILE__), 'lu_water_heater_efficiency.csv'), headers: true) do |row|
    next unless row['performance_id'] == performance_id
    next unless row['fuel_primary_id'] == fuel_primary_id

    row_year = Integer(row['year'])
    if (row_year - year).abs <= (lookup_year - year).abs
      lookup_year = row_year
      value = Float(row['value'])
    end
  end
  fail 'Could not lookup default water heating efficiency.' if value.nil?

  return value
end

def get_default_water_heater_volume(fuel)
  # Water Heater Tank Volume by fuel
  val = { HPXML::FuelTypeElectricity => 50,
          HPXML::FuelTypeNaturalGas => 40,
          HPXML::FuelTypePropane => 40,
          HPXML::FuelTypeOil => 32 }[fuel]
  return val if not val.nil?

  fail "Could not get default water heater volume for fuel '#{fuel}'"
end

def get_default_water_heater_capacity(fuel)
  # Water Heater Rated Input Capacity by fuel
  val = { HPXML::FuelTypeElectricity => 15400,
          HPXML::FuelTypeNaturalGas => 38000,
          HPXML::FuelTypePropane => 38000,
          HPXML::FuelTypeOil => 90000 }[fuel]
  return val if not val.nil?

  fail "Could not get default water heater capacity for fuel '#{fuel}'"
end

def get_wall_effective_r_from_doe2code(doe2code)
  val = nil
  CSV.foreach(File.join(File.dirname(__FILE__), 'lu_wall_eff_rvalue.csv'), headers: true) do |row|
    next unless row['doe2code'] == doe2code

    val = Float(row['Eff-R-value'])
    break
  end
  return val
end

$siding_map = {
  HPXML::SidingTypeWood => 'wo',
  HPXML::SidingTypeStucco => 'st',
  HPXML::SidingTypeVinyl => 'vi',
  HPXML::SidingTypeAluminum => 'al',
  HPXML::SidingTypeBrick => 'br',
  nil => 'nn'
}

$wall_type_map = {
  'wf' => HPXML::WallTypeWoodStud,
  'ps' => HPXML::WallTypeWoodStud,
  'ov' => HPXML::WallTypeWoodStud,
  'br' => HPXML::WallTypeBrick,
  'cb' => HPXML::WallTypeCMU,
  'sb' => HPXML::WallTypeStrawBale
}

def get_roof_effective_r_from_doe2code(doe2code)
  # For wood frame with radiant barrier roof, use wood frame roof effective R-value. Radiant barrier will be handled by the actual radiant barrier model in OS.
  if doe2code[2,2] == 'rb'
    doe2code = doe2code.gsub('rb', 'wf')
  end
  val = nil
  CSV.foreach(File.join(File.dirname(__FILE__), 'lu_roof_eff_rvalue.csv'), headers: true) do |row|
    next unless row['doe2code'] == doe2code

    val = Float(row['Eff-R-value'])
    break
  end
  return val
end

def get_ceiling_effective_r_from_doe2code(doe2code)
  val = nil
  CSV.foreach(File.join(File.dirname(__FILE__), 'lu_ceiling_eff_rvalue.csv'), headers: true) do |row|
    next unless row['doe2code'] == doe2code

    val = Float(row['Eff-R-value'])
    break
  end
  return val
end

def get_floor_effective_r_from_doe2code(doe2code)
  val = nil
  CSV.foreach(File.join(File.dirname(__FILE__), 'lu_floor_eff_rvalue.csv'), headers: true) do |row|
    next unless row['doe2code'] == doe2code

    val = Float(row['Eff-R-value'])
    break
  end
  return val
end

def get_window_skylight_ufactor_shgc_from_doe2code(doe2code)
  window_ufactor_shgc = {
    'scna' => [1.27, 0.75],
    'scnw' => [0.89, 0.64],
    'stna' => [1.27, 0.64],
    'stnw' => [0.89, 0.54],
    'dcaa' => [0.81, 0.67],
    'dcab' => [0.60, 0.67],
    'dcaw' => [0.51, 0.56],
    'dtaa' => [0.81, 0.55],
    'dtab' => [0.60, 0.55],
    'dtaw' => [0.51, 0.46],
    'dpeaw' => [0.42, 0.52],
    'dpeaab' => [0.47, 0.62],
    'dpeaaw' => [0.39, 0.52],
    'dseaa' => [0.67, 0.37],
    'dseab' => [0.47, 0.37],
    'dseaw' => [0.39, 0.31],
    'dseaaw' => [0.36, 0.31],
    'thmabw' => [0.27, 0.31]
  }[doe2code]
  return window_ufactor_shgc if not window_ufactor_shgc.nil?

  fail "Could not get default window U/SHGC for window code '#{doe2code}'"
end

def get_skylight_ufactor_shgc(frame_type, thermal_break, glass_layers, glass_type, gas_fill)
  # Skylight U-factor/SHGC
  key = [frame_type, thermal_break, glass_layers, glass_type, gas_fill]
  vals = { [HPXML::WindowFrameTypeAluminum, false, HPXML::WindowLayersSinglePane, nil, nil] => [1.98, 0.75], # scna
           [HPXML::WindowFrameTypeWood, nil, HPXML::WindowLayersSinglePane, nil, nil] => [1.47, 0.64], # scnw
           [HPXML::WindowFrameTypeAluminum, false, HPXML::WindowLayersSinglePane, HPXML::WindowGlazingTintedReflective, nil] => [1.98, 0.64], # stna
           [HPXML::WindowFrameTypeWood, nil, HPXML::WindowLayersSinglePane, HPXML::WindowGlazingTintedReflective, nil] => [1.47, 0.54], # stnw
           [HPXML::WindowFrameTypeAluminum, false, HPXML::WindowLayersDoublePane, nil, HPXML::WindowGasAir] => [1.30, 0.67], # dcaa
           [HPXML::WindowFrameTypeAluminum, true, HPXML::WindowLayersDoublePane, nil, HPXML::WindowGasAir] => [1.10, 0.67], # dcab
           [HPXML::WindowFrameTypeWood, nil, HPXML::WindowLayersDoublePane, nil, HPXML::WindowGasAir] => [0.84, 0.56], # dcaw
           [HPXML::WindowFrameTypeAluminum, false, HPXML::WindowLayersDoublePane, HPXML::WindowGlazingTintedReflective, HPXML::WindowGasAir] => [1.30, 0.55], # dtaa
           [HPXML::WindowFrameTypeAluminum, true, HPXML::WindowLayersDoublePane, HPXML::WindowGlazingTintedReflective, HPXML::WindowGasAir] => [1.10, 0.55], # dtab
           [HPXML::WindowFrameTypeWood, nil, HPXML::WindowLayersDoublePane, HPXML::WindowGlazingTintedReflective, HPXML::WindowGasAir] => [0.84, 0.46], # dtaw
           [HPXML::WindowFrameTypeWood, nil, HPXML::WindowLayersDoublePane, HPXML::WindowGlazingLowE, HPXML::WindowGasAir] => [0.74, 0.52], # dpeaw
           [HPXML::WindowFrameTypeAluminum, true, HPXML::WindowLayersDoublePane, HPXML::WindowGlazingLowE, HPXML::WindowGasArgon] => [0.95, 0.62], # dpeaab
           [HPXML::WindowFrameTypeWood, nil, HPXML::WindowLayersDoublePane, HPXML::WindowGlazingLowE, HPXML::WindowGasArgon] => [0.68, 0.52], # dpeaaw
           [HPXML::WindowFrameTypeAluminum, false, HPXML::WindowLayersDoublePane, HPXML::WindowGlazingReflective, HPXML::WindowGasAir] => [1.17, 0.37], # dseaa
           [HPXML::WindowFrameTypeAluminum, true, HPXML::WindowLayersDoublePane, HPXML::WindowGlazingReflective, HPXML::WindowGasAir] => [0.98, 0.37], # dseab
           [HPXML::WindowFrameTypeWood, nil, HPXML::WindowLayersDoublePane, HPXML::WindowGlazingReflective, HPXML::WindowGasAir] => [0.71, 0.31], # dseaw
           [HPXML::WindowFrameTypeWood, nil, HPXML::WindowLayersDoublePane, HPXML::WindowGlazingReflective, HPXML::WindowGasArgon] => [0.65, 0.31], # dseaaw
           [HPXML::WindowFrameTypeWood, nil, HPXML::WindowLayersTriplePane, HPXML::WindowGlazingLowE, HPXML::WindowGasArgon] => [0.47, 0.31] }[key] # thmabw
  return vals if not vals.nil?

  fail "Could not get default skylight U/SHGC for frame type '#{frame_type}' and glass layers '#{glass_layers}' and glass type '#{glass_type}' and gas fill '#{gas_fill}'"
end

def get_roof_solar_absorptance(roof_color)
  val = { HPXML::ColorReflective => 0.35,
          HPXML::ColorLight => 0.55,
          HPXML::ColorMedium => 0.7,
          HPXML::ColorMediumDark => 0.8,
          HPXML::ColorDark => 0.9 }[roof_color]
  return val if not val.nil?

  fail "Could not get roof absorptance for color '#{roof_color}'"
end

def calc_duct_values(ncfl_ag, cfa, is_sealed, frac_inside)
  # Total leakage fraction of air handler flow
  if is_sealed
    total_leakage_frac = 0.10
  else
    total_leakage_frac = 0.25
  end

  # Fraction of ducts that are outside conditioned space
  if frac_inside > 0
    f_out_s = 1.0 - frac_inside
  else
    # Make assumption
    if ncfl_ag == 1
      f_out_s = 1.0
    else
      f_out_s = 0.65
    end
  end
  if frac_inside == 1
    f_out_r = 0.0
  else
    f_out_r = 1.0
  end

  # Duct leakages to the outside (assume total leakage equally split between supply/return)
  lto_s = total_leakage_frac / 2.0 * f_out_s
  lto_r = total_leakage_frac / 2.0 * f_out_r

  # Duct surface areas that are outside conditioned space
  uncond_area_s = 0.27 * f_out_s * cfa
  uncond_area_r = 0.05 * ncfl_ag * f_out_r * cfa

  return lto_s.round(5), lto_r.round(5), uncond_area_s.round(2), uncond_area_r.round(2)
end

def calc_ach50(ncfl_ag, cfa, ceil_height, cvolume, desc, year_built, iecc_cz, fnd_types, ducts)
  # Constants
  c_floor_area = -0.002078
  c_height = 0.06375

  # Vintage
  c_vintage = nil
  if year_built < 1960
    c_vintage = -0.2498
  elsif year_built <= 1969
    c_vintage = -0.4327
  elsif year_built <= 1979
    c_vintage = -0.4521
  elsif year_built <= 1989
    c_vintage = -0.6536
  elsif year_built <= 1999
    c_vintage = -0.9152
  elsif year_built >= 2000
    c_vintage = -1.058
  else
    fail "Unexpected vintage: #{year_built}"
  end

  # Climate zone
  c_iecc = nil
  if (iecc_cz == '1A') || (iecc_cz == '2A')
    c_iecc = 0.4727
  elsif iecc_cz == '3A'
    c_iecc = 0.2529
  elsif iecc_cz == '4A'
    c_iecc = 0.3261
  elsif iecc_cz == '5A'
    c_iecc = 0.1118
  elsif (iecc_cz == '6A') || (iecc_cz == '7')
    c_iecc = 0.0
  elsif (iecc_cz == '2B') || (iecc_cz == '3B')
    c_iecc = -0.03755
  elsif (iecc_cz == '4B') || (iecc_cz == '5B')
    c_iecc = -0.008774
  elsif iecc_cz == '6B'
    c_iecc = 0.01944
  elsif iecc_cz == '3C'
    c_iecc = 0.04827
  elsif iecc_cz == '4C'
    c_iecc = 0.2584
  elsif iecc_cz == '8'
    c_iecc = -0.5119
  else
    fail "Unexpected IECC climate zone: #{c_iecc}"
  end

  # Foundation type (weight by area)
  c_foundation = 0.0
  sum_fnd_area = 0.0
  fnd_types.each do |fnd_type, area|
    sum_fnd_area += area
    if fnd_type == 'slab_on_grade'
      c_foundation += -0.036992 * area
    elsif (fnd_type == 'cond_basement') || (fnd_type == 'unvented_crawl')
      c_foundation += 0.108713 * area
    elsif (fnd_type == 'uncond_basement') || (fnd_type == 'vented_crawl')
      c_foundation += 0.180352 * area
    else
      fail "Unexpected foundation type: #{fnd_type}"
    end
  end
  c_foundation /= sum_fnd_area

  # Ducts (weighted by duct fraction and hvac fraction)
  sum_duct_hvac_frac = 0.0
  ducts.each do |hvac_frac, duct_frac, duct_location|
    sum_duct_hvac_frac += (duct_frac * hvac_frac)
  end
  if sum_duct_hvac_frac > 1.0001 # Using 1.0001 to allow small tolerance on sum
    fail "Unexpected sum of duct fractions: #{sum_duct_hvac_frac}."
  elsif sum_duct_hvac_frac < 1.0 # i.e., there is at least one ductless system
    # Add 1.0 - sum_duct_hvac_frac as ducts in conditioned space.
    # This will ensure ductless systems have same result as ducts in conditioned space.
    # See https://github.com/NREL/OpenStudio-HEScore/issues/211
    ducts << [1.0 - sum_duct_hvac_frac, 1.0, HPXML::LocationLivingSpace]
  end

  c_duct = 0.0
  ducts.each do |hvac_frac, duct_frac, duct_location|
    if duct_location == 'cond_space'
      c_duct += -0.12381 * duct_frac * hvac_frac
    elsif (duct_location == 'uncond_attic') || (duct_location == 'uncond_basement')
      c_duct += 0.07126 * duct_frac * hvac_frac
    elsif duct_location == 'vented_crawl'
      c_duct += 0.18072 * duct_frac * hvac_frac
    elsif duct_location == 'unvented_crawl'
      c_duct += 0.07126 * duct_frac * hvac_frac
    else
      fail "Unexpected duct location: #{duct_location}"
    end
  end

  c_sealed = nil
  if desc == HPXML::LeakinessTight
    c_sealed = -0.288
  elsif desc == HPXML::LeakinessAverage
    c_sealed = 0.0
  else
    fail "Unexpected air leakage description: #{desc}"
  end

  floor_area_m2 = UnitConversions.convert(cfa, 'ft^2', 'm^2')
  height_m = UnitConversions.convert(ncfl_ag * ceil_height, 'ft', 'm') + 0.5

  # Normalized leakage
  nl = Math.exp(floor_area_m2 * c_floor_area +
                height_m * c_height +
                c_sealed + c_vintage + c_iecc + c_foundation + c_duct)

  # Specific Leakage Area
  sla = nl / (1000.0 * ncfl_ag**0.3)

  ach50 = Airflow.get_infiltration_ACH50_from_SLA(sla, 0.65, cfa, cvolume)

  return ach50
end

def orientation_to_azimuth(orientation)
  return { 'north_east' => 45,
           'east' => 90,
           'south_east' => 135,
           'south' => 180,
           'south_west' => 225,
           'west' => 270,
           'north_west' => 315,
           'north' => 0 }[orientation]
end

def wall_orientation_to_azimuth(orientation)
  return { 'front' => @bldg_azimuth,
           'right' => @bldg_azimuth + 90,
           'back' => @bldg_azimuth + 180,
           'left' => @bldg_azimuth + 270}[orientation]
end

def reverse_orientation(orientation)
  # Converts, e.g., "northwest" to "southeast"
  reverse = orientation
  if reverse.include? HPXML::OrientationNorth
    reverse = reverse.gsub(HPXML::OrientationNorth, HPXML::OrientationSouth)
  else
    reverse = reverse.gsub(HPXML::OrientationSouth, HPXML::OrientationNorth)
  end
  if reverse.include? HPXML::OrientationEast
    reverse = reverse.gsub(HPXML::OrientationEast, HPXML::OrientationWest)
  else
    reverse = reverse.gsub(HPXML::OrientationWest, HPXML::OrientationEast)
  end
  return reverse
end

def sanitize_azimuth(azimuth)
  # Ensure 0 <= orientation < 360
  while azimuth < 0
    azimuth += 360
  end
  while azimuth >= 360
    azimuth -= 360
  end
  return azimuth
end

def hpxml_to_hescore_fuel(fuel_type)
  return { HPXML::FuelTypeElectricity => 'electric',
           HPXML::FuelTypeNaturalGas => 'natural_gas',
           HPXML::FuelTypeOil => 'fuel_oil',
           HPXML::FuelTypePropane => 'lpg' }[fuel_type]
end

def get_foundation_areas(json)
  # Returns a hash of foundation location => area
  fnd_types = {}
  json['building']['zone']['zone_floor'].each do |orig_foundation|
    fnd_types[orig_foundation['foundation_type']] = orig_foundation['floor_area']
  end
  return fnd_types
end

def get_ducts_details(json)
  # Returns a list of [hvac_frac, duct_frac, duct_location]
  ducts = []
  json['building']['systems']['hvac'].each do |orig_hvac|
    hvac_frac = orig_hvac['hvac_fraction'] / 100  # get_hvac_fraction(json, orig_dist['name'])

    orig_hvac['hvac_distribution'].each do |orig_duct|
      ducts << [hvac_frac, orig_duct['fraction'], orig_duct['location']]
    end
  end
  return ducts
end

# def get_hvac_fraction(json, dist_id)
#   json.heating_systems.each do |orig_heating|
#     next unless orig_heating.distribution_system_idref == dist_id
#     next unless orig_heating.fraction_heat_load_served > 0

#     return orig_heating.fraction_heat_load_served
#   end
#   json.cooling_systems.each do |orig_cooling|
#     next unless orig_cooling.distribution_system_idref == dist_id
#     next unless orig_cooling.fraction_cool_load_served > 0

#     return orig_cooling.fraction_cool_load_served
#   end
#   json.heat_pumps.each do |orig_hp|
#     next unless orig_hp.distribution_system_idref == dist_id

#     if orig_hp.fraction_cool_load_served > 0
#       return orig_hp.fraction_cool_load_served
#     elsif orig_hp.fraction_heat_load_served > 0
#       return orig_hp.fraction_heat_load_served
#     end
#   end
#   return
# end

def calc_conditioned_volume(json)
  cvolume = @cfa * @ceil_height
  json['building']['zone']['zone_roof'].each do |orig_roof|
    is_conditioned_attic = (orig_roof['roof_type'] == 'cond_attic')
    is_cathedral_ceiling = (orig_roof['roof_type'] == 'cath_ceiling')
    next unless is_conditioned_attic || is_cathedral_ceiling

    # Half of the length of short side of the house
    a = 0.5 * [@bldg_length_front, @bldg_length_side].min
    # Ridge height
    b = a * Math.tan(@roof_angle_rad)
    # The hypotenuse
    c = a / Math.cos(@roof_angle_rad)
    # The depth this attic area goes back on the non-gable side
    d = 0.5 * orig_roof['roof_area'] / c

    if is_conditioned_attic
      # Remove erroneous full height volume from the conditioned volume
      cvolume -= @ceil_height * 2 * a * d
    end

    # Add the volume under the roof and above the "ceiling"
    cvolume += d * a * b
  end
  return cvolume
end
