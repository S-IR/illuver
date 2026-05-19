
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

  // adwaron
  EnchantedSoil,
  EnchantedPasture,
  MagicAbsorbingRock,
  PulsingStone,

  // gorglai

  // rock at the top
  Peakor,
  // strip rock thats meant to go up and down around a mountain
  MawbeakRock,
  // mushroom red soil
  AvigniSoil,
  // default gorglai dirt
  Gorgveil,
  // wild life product grass
  AstanaiGrass,
  // first level rock gorglai
  Canyonite,
  // second level rock gorglai
  Avrasar,
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
    return float3(189.5, 131.2, 68.7) / 255.0;
  case PointType::PurpleGround:
    return float3(58.3, 22.7, 138.5) / 255.0;
  case PointType::LightPurpleGround:
    return float3(162.8, 88.4, 252.1) / 255.0;
  case PointType::BlueDiamond:
    return float3(18.4, 245.6, 238.2) / 255.0;
  case PointType::BlackCliff:
    return float3(38.5, 30.2, 46.8) / 255.0;
  case PointType::PinkTrunk:
    return float3(233.1, 98.7, 118.4) / 255.0;
  case PointType::WhiteTreeLeaf:
    return float3(225.3, 195.8, 252.4) / 255.0;
  case PointType::Water:
    return float3(0,0,0) / 255.0;
  case PointType::GlassGrass:
    return float3(218.4, 205.7, 72.3) / 255.0;
  case PointType::VoidLoam:
    return float3(72.6, 48.3, 32.8) / 255.0;
  case PointType::VeilStone:
    return float3(78.4, 95.7, 148.2) / 255.0;
  case PointType::AbyssStone:
    return float3(22.3, 52.8, 38.5) / 255.0;
  case PointType::SharditeMineral:
    return float3(138.6, 218.3, 255.0) / 255.0;
  case PointType::ColossalShard:
    return float3(55.4, 168.7, 225.3) / 255.0;
  case PointType::AshwoodTrunk:
    return float3(88.5, 78.2, 68.7) / 255.0;
  case PointType::AshwoodLeaf:
    return float3(112.3, 132.6, 85.4) / 255.0;
  case PointType::UmbraTrunk:
    return float3(32.4, 20.7, 28.3) / 255.0;
  case PointType::UmbraLeaf:
    return float3(58.6, 28.3, 68.7) / 255.0;
  case PointType::CrystalTrunk:
    return float3(198.4, 148.7, 238.3) / 255.0;
  case PointType::CrystalLeaf:
    return float3(182.5, 242.3, 252.7) / 255.0;
  case PointType::EnchantedSoil:
    return float3(48.3, 28.7, 92.4) / 255.0;
  case PointType::EnchantedPasture:
    return float3(65.4, 42.8, 215.6) / 255.0;
  case PointType::MagicAbsorbingRock:
    return float3(215.3, 135.6, 188.4) / 255.0;
  case PointType::PulsingStone:
    return float3(188.7, 38.4, 205.3) / 255.0;
  case PointType::Peakor:
    return float3(178.4, 152.7, 118.3) / 255.0;
  case PointType::MawbeakRock:
    return float3(92.6, 82.3, 95.7) / 255.0;
  case PointType::AvigniSoil:
    return float3(125.4, 48.7, 35.3) / 255.0;
  case PointType::Gorgveil:
    return float3(158.3, 92.6, 42.4) / 255.0;
  case PointType::AstanaiGrass:
    return float3(82.4, 152.7, 38.3) / 255.0;
  case PointType::Canyonite:
    return float3(202.6, 148.3, 68.7) / 255.0;
  case PointType::Avrasar:
    return float3(118.4, 62.7, 35.3) / 255.0;
  default:
    return float3(0.0);
  }
}
bool isTransparentPoint(PointType type) {
    switch (type) {
        case PointType::Water:
        return true;
        default:
        return false;
    };
    return false;
}
export float4 pointFinalColor(uint16_t point) {
  float3 base = baseColor(getPointType(point));
  float3 energy = energyToColor(point);
  float3 combined = base * 0.9 + energy * 0.1;
  float alpha = (getPointType(point) == PointType::Water) ?  0.7: 1.0;
  return float4(combined, alpha);
}
