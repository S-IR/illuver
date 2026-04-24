
static const uint TYPE_MASK = 1023u;
static const uint ENERGY_MASK = 3u;
static const uint LIGHT_SHIFT = 10;
static const uint LIFE_SHIFT = 12;
static const uint WISDOM_SHIFT = 14;

export enum PointType : uint16_t {
  Air,
  YellowDirt,
  PurpleGround,
  LightPurpleGround,
  BlueDiamond,
  BlackCliff,
  PinkTrunk,
  WhiteTreeLeaf,
  Water,
  GlassGrass,
  VoidLoam,
  VeilStone,
  AbyssStone,
  SharditeMineral,
  ColossalShard,
  AshwoodTrunk,
  AshwoodLeaf,
  UmbraTrunk,
  UmbraLeaf,
  CrystalTrunk,
  CrystalLeaf,
};

PointType getPointType(uint16_t p) { return PointType(uint(p) & TYPE_MASK); }
uint getLight(uint16_t p) { return (uint(p) >> LIGHT_SHIFT) & ENERGY_MASK; }
uint getLife(uint16_t p) { return (uint(p) >> LIFE_SHIFT) & ENERGY_MASK; }
uint getWisdom(uint16_t p) { return (uint(p) >> WISDOM_SHIFT) & ENERGY_MASK; }

float3 energyToColor(uint16_t p) {
  float light = float(getLight(p)) / 3.0;
  float life = float(getLife(p)) / 3.0;
  float wisdom = float(getWisdom(p)) / 3.0;
  return float3(light, light + life, wisdom);
}

float3 baseColor(PointType type) {
  switch (type) {
  case PointType::YellowDirt:
    return float3(159, 112, 75) / 255.0;
  case PointType::PurpleGround:
    return float3(36, 19, 97) / 255.0;
  case PointType::LightPurpleGround:
    return float3(141, 97, 237) / 255.0;
  case PointType::BlueDiamond:
    return float3(0, 236, 231) / 255.0;
  case PointType::BlackCliff:
    return float3(31, 22, 25) / 255.0;
  case PointType::PinkTrunk:
    return float3(229, 108, 125) / 255.0;
  case PointType::WhiteTreeLeaf:
    return float3(218, 189, 252) / 255.0;
  case PointType::Water:
    return float3(68, 131, 129) / 255.0;
  case PointType::GlassGrass:
    return float3(210, 195, 100) / 255.0;
  case PointType::VoidLoam:
    return float3(38, 28, 22) / 255.0;
  case PointType::VeilStone:
    return float3(90, 100, 130) / 255.0;
  case PointType::AbyssStone:
    return float3(22, 35, 30) / 255.0;
  case PointType::SharditeMineral:
    return float3(160, 220, 255) / 255.0;
  case PointType::ColossalShard:
    return float3(80, 160, 200) / 255.0;
  case PointType::AshwoodTrunk:
    return float3(70, 70, 75) / 255.0;
  case PointType::AshwoodLeaf:
    return float3(95, 105, 90) / 255.0;
  case PointType::UmbraTrunk:
    return float3(20, 15, 18) / 255.0;
  case PointType::UmbraLeaf:
    return float3(35, 25, 40) / 255.0;
  case PointType::CrystalTrunk:
    return float3(180, 140, 220) / 255.0;
  case PointType::CrystalLeaf:
    return float3(200, 240, 255) / 255.0;

  default:
    return float3(0.0);
  }
}
export float4 pointFinalColor(uint16_t point) {
  float3 base = baseColor(getPointType(point));
  float3 energy = energyToColor(point);
  float3 combined = base * 0.9 + energy * 0.1;
  return float4(combined, 1.0);
}
