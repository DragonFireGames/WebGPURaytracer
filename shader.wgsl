@id(0) override BOUNCE_LIMIT: i32 = 8;
@id(1) override HAS_SPHERES: bool = true;
@id(2) override HAS_CUBES: bool = true;
@id(3) override HAS_PLANES: bool = true;
@id(4) override HAS_CYLINDERS: bool = true;
@id(5) override HAS_TORI: bool = true;
@id(6) override HAS_MESHES: bool = true;
@id(7) override HAS_LIST_MESHES: bool = true;
@id(8) override HAS_HEIGHTMAPS: bool = true;
@id(9) override HAS_LIGHTS: bool = true;
@id(10) override HAS_SKYBOX: bool = true;
@id(11) override MIS_SKYBOX: bool = true;

const PI: f32 = 3.14159265359;
const TWO_PI: f32 = 6.28318530718;
const INFINITY: f32 = 65504.0;
const STACK_SIZE: u32 = 64;

struct Ray {
  origin: vec3f,
  direction: vec3f
};
struct SceneParams {
  eye: vec3f, sample_number: u32, ray00: vec3f, width: u32, ray10: vec3f, height: u32, ray01: vec3f, exposure: f32,
  ray11: vec3f, seed: u32,
  sky_width: u32,
  sky_height: u32,
  sky_total_lum: f32,
  total_light_power: f32,
  section: vec2u,
  sky_cdf_index: u32,
  pad0: f32,
};

struct Material {
  color: vec3f,
  metallic: f32, roughness: f32,
  ior: f32,
  specular_tint: f32,
  anisotropic: f32, aniso_rotation: f32,
  sheen: f32,
  sheen_tint: f32,
  clearcoat: f32, clearcoat_gloss: f32,
  clearcoat_ior: f32,
  transmission: f32,
  concentration: f32, subsurface_tint: vec3f,
  subsurface: f32, emittance: vec3f,
  emissive_idx: i32, albedo_idx: i32,
  normal_idx: i32,
  height_idx: i32,
  roughness_idx: i32, metallic_idx: i32,
  _pad1: f32,
  uv_scale: vec2f, height_params: vec4f, // x: norm_mult, y: multiplier, z: samples, w: offset
};

struct TransformedObject { 
  inv_matrix: mat4x4f,
  material_idx: i32,
  light_idx: i32,
  object_type: i32,
  param0: f32, world_position: vec3f,
  param1: f32,
};

struct Plane { 
  normal: vec3f,
  d: f32,
  material_idx: i32,
  pad0: f32, pad1: f32, pad2: f32
};

struct Cylinder { 
  inv_matrix: mat4x4f,
  material_idx: i32,
  top_radius: f32,
};

struct Torus { 
  inv_matrix: mat4x4f,
  material_idx: i32,
  inner_radius: f32,
};

struct Triangle {
  v0: vec3f, pad0: f32,
  v1: vec3f, pad1: f32,
  v2: vec3f, pad2: f32,
  n0: vec3f, pad3: f32,
  n1: vec3f, pad4: f32,
  n2: vec3f, pad5: f32,
  uv0: vec2f, uv1: vec2f, uv2: vec2f, pad6: vec2f
};

struct MeshInstance {
  inv_matrix: mat4x4f,
  material_idx: i32,
  pad: i32,
  node_offset: u32,
  tri_offset: u32,
};

struct BVHNode {
  aabb_min: vec3f,
  num_triangles: u32,
  aabb_max: vec3f,
  next: u32, // right child or triangle start index
};

struct Light {
  obj_idx: i32,
  area: f32,
  power: f32,
  scale: f32,
  matrix: mat4x4f,
};

struct SurfaceHit {
  t: f32, m_idx: i32,
  hit_p: vec3f, hit_n: vec3f, hit_uv: vec2f,
  tangent: vec3f, bitangent: vec3f,
  o_idx: i32,
  count: i32,
};

@group(0) @binding(0) var<uniform> params: SceneParams;
@group(0) @binding(1) var<storage, read_write> accum_buffer: array<vec4f>;
@group(0) @binding(2) var output_tex: texture_storage_2d<rgba8unorm, write>;
@group(0) @binding(3) var<storage, read> materials: array<Material>;
@group(0) @binding(4) var<storage, read> objects: array<TransformedObject>;
@group(0) @binding(5) var<storage, read> tlas_nodes: array<BVHNode>;
@group(0) @binding(6) var<storage, read> meshes: array<MeshInstance>;
@group(0) @binding(7) var<storage, read> bvh_nodes: array<BVHNode>;
@group(0) @binding(8) var<storage, read> triangles: array<Triangle>;
@group(0) @binding(9) var<storage, read> planes: array<Plane>;
@group(0) @binding(10) var<storage, read> lights: array<Light>;

// 8 Texture Bindings for rich materials
@group(0) @binding(11) var texture_list: texture_2d_array<f32>;
@group(0) @binding(12) var texture_sampler: sampler;

// skybox
@group(0) @binding(13) var skyTex: texture_2d<f32>;
@group(0) @binding(14) var skySampler: sampler;
@group(0) @binding(15) var<storage, read> sky_cdf: array<f32>;

var<private> rng_state: u32;
fn rand_pcg() -> f32 {
  let state = rng_state;
  rng_state = state * 747796405u + 2891336453u;
  var word: u32 = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
  word = (word >> 22u) ^ word;
  //return f32(word) / 4294967296.0;
  return f32(word) * 2.3283064365386963e-10;
}

fn max_component(v: vec3f) -> f32 {
  return max(max(v.x,v.y),v.z);
}
fn min_component(v: vec3f) -> f32 {
  return min(min(v.x,v.y),v.z);
}

fn random_unit_vector() -> vec3f {
  let z = rand_pcg() * 2.0 - 1.0;
  let a = rand_pcg() * TWO_PI;
  let r = sqrt(1.0 - z * z);
  return vec3f(r * cos(a), r * sin(a), z);
}

fn sample_texture(idx: i32, uv: vec2f) -> vec4f {
  if (idx < 0) { return vec4f(1.0); }
  return textureSampleLevel(texture_list, texture_sampler, uv, u32(idx), 0.0);
}

// WGSL function to sample the sky
fn sample_sky(dir: vec3f) -> vec3f {
  // Convert direction to spherical coordinates
  let phi = atan2(dir.z, dir.x);      // -PI to PI
  let theta = asin(clamp(dir.y, -1.0, 1.0)); // -PI/2 to PI/2
  
  // Map to 0.0 - 1.0 range
  let u = 0.5 + phi / TWO_PI;
  let v = 0.5 - theta / PI;
  
  // Sample your texture (assuming it's in a binding called 'skyTex')
  // We use a sampler with linear filtering for smooth skies
  return textureSampleLevel(skyTex, skySampler, vec2f(u, v), 0.0).rgb;
}

// Generic binary search for CDF arrays
// search_in: 0 for cond_cdf, 1 for marg_cdf
fn binary_search_cdf(search_in: u32, offset: u32, size: u32, targ: f32) -> u32 {
  var low: u32 = 0u;
  var high: u32 = size;
  while (low < high) {
    let mid = low + (high - low) / 2u;
    var val: f32;
    if (search_in == 0u) {
      val = sky_cdf[offset + mid];
    } else {
      val = sky_cdf[offset + mid + params.sky_cdf_index];
    }
    if (val < targ) {
      low = mid + 1u;
    } else {
      high = mid;
    }
  }
  return max(1u, low) - 1u;
}

fn get_sky_pdf(dir: vec3f) -> f32 {
  let phi = atan2(dir.z, dir.x);
  let theta = acos(clamp(dir.y, -1.0, 1.0));
  
  // Map to [0, 1] UV space
  let u = (phi + PI) / (2.0 * PI);
  let v = theta / PI;
  
  // Sample color to get luminance (MUST match JS logic exactly)
  let sky_color = textureSampleLevel(skyTex, skySampler, vec2f(u, v), 0.0).rgb;
  let lum = dot(sky_color, vec3f(0.2126, 0.7152, 0.0722));
  let sin_theta = sin(theta);

  if (params.sky_total_lum <= 0.0 || sin_theta <= 0.0) {
    return 1.0 / (4.0 * PI);
  }

  // Calculate PDF
  let pdf = (lum * f32(params.sky_width) * f32(params.sky_height)) / (params.sky_total_lum * 2 * PI * PI);
  
  return pdf; // / (4.0 * PI);
}

fn sample_env_cdf(u: vec2f) -> LightSample {
  var samp: LightSample;
  
  // Binary search to find row and column (as you already have)
  let v_idx = binary_search_cdf(1u, 0u, params.sky_height, u.y);
  let row_offset = v_idx * (params.sky_width + 1u);
  let u_idx = binary_search_cdf(0u, row_offset, params.sky_width, u.x);

  let u_coord = (f32(u_idx) + 0.5) / f32(params.sky_width);
  let v_coord = (f32(v_idx) + 0.5) / f32(params.sky_height);
  
  let theta = PI * v_coord;
  let phi = 2.0 * PI * u_coord - PI;
  
  let sin_theta = sin(theta);
  samp.dir = vec3f(sin_theta * cos(phi), cos(theta), sin_theta * sin(phi));
  samp.color = textureSampleLevel(skyTex, skySampler, vec2f(u_coord, v_coord), 0.0).rgb;
  
  // Reuse the PDF logic
  samp.pdf = get_sky_pdf(samp.dir);
  samp.dist = INFINITY;
  
  return samp;
}

fn intersect_aabb(origin: vec3f, inv_dir: vec3f, aabb_min: vec3f, aabb_max: vec3f) -> f32 {
  let t0 = (aabb_min - origin) * inv_dir;
  let t1 = (aabb_max - origin) * inv_dir;
  let tmin = min(t0, t1);
  let tmax = max(t0, t1);
  let t_near = max_component(tmin);
  let t_far = min_component(tmax);
  if (t_near > t_far || t_far < 0.0) { return -1.; }//{ return 9999999.0; }
  return select(t_near, 0.0, t_near < 0.0);
}

fn intersect_triangle(ray: Ray, tri: Triangle, hit_t: ptr<function, f32>, hit_uv: ptr<function, vec2f>, bary: ptr<function, vec3f>) -> bool {
  let edge1 = tri.v1 - tri.v0;
  let edge2 = tri.v2 - tri.v0;
  let h = cross(ray.direction, edge2);
  let a = dot(edge1, h);
  if (abs(a) < 0.000001) { return false; } 
  let f = 1.0 / a;
  let s = ray.origin - tri.v0;
  let u = f * dot(s, h);
  if (u < 0.0 || u > 1.0) { return false; }
  let q = cross(s, edge1);
  let v = f * dot(ray.direction, q);
  if (v < 0.0 || u + v > 1.0) { return false; }
  let t = f * dot(edge2, q);
  if (t > 0.000001) {
    *hit_t = t;
    *bary = vec3f(1.0 - u - v, u, v);
    *hit_uv = tri.uv0 * bary.x + tri.uv1 * bary.y + tri.uv2 * bary.z;
    return true;
  }
  return false;
}

fn hit_unit_sphere(r: Ray) -> f32 {
  let a = dot(r.direction, r.direction);
  let half_b = dot(r.origin, r.direction);
  let c = dot(r.origin, r.origin) - 1.0;
  let discriminant = half_b * half_b - a * c;
  if (discriminant < 0.0) { return -1.0; }
  let sqrtd = sqrt(discriminant);
  var root = (-half_b - sqrtd) / a;
  if (root < 0.001) { root = (-half_b + sqrtd) / a; }
  return select(-1.0, root, root >= 0.001);
}

fn hit_unit_cube(r: Ray) -> f32 {
  let inv_dir = 1.0 / r.direction;
  let t0 = (-1.0 - r.origin) * inv_dir;
  let t1 = (1.0 - r.origin) * inv_dir;
  let tmin = min(t0, t1);
  let tmax = max(t0, t1);
  let tnear = max_component(tmin);
  let tfar = min_component(tmax);
  if (tnear < tfar && tfar > 0.0) { return select(tfar, tnear, tnear > 0.001); }
  return -1.0;
}

fn hit_plane(normal: vec3f, d: f32, r: Ray) -> f32 {
  let denom = dot(normal, r.direction);
  if (abs(denom) > 1e-6) {
    let t = (d - dot(normal, r.origin)) / denom;
    if (t > 0.001) { return t; }
  }
  return -1.0;
}

fn hit_cylinder(r: Ray, r0: f32, r1: f32, t_out: ptr<function, f32>, n_out: ptr<function, vec3f>, uv_out: ptr<function, vec2f>) -> bool {
  let h = 1.0;
  let dr = r1 - r0;
  
  // Quadratic coefficients for a cone/cylinder side
  let k = dr / h;
  let origin_eff_radius = r0 + k * r.origin.y;
  
  let A = r.direction.x * r.direction.x + r.direction.z * r.direction.z - k * k * r.direction.y * r.direction.y;
  let B = 2.0 * (r.origin.x * r.direction.x + r.origin.z * r.direction.z - origin_eff_radius * k * r.direction.y);
  let C = r.origin.x * r.origin.x + r.origin.z * r.origin.z - origin_eff_radius * origin_eff_radius;

  var t_min = 1e10;
  var hit = false;

  // 1. Check side intersection
  let disc = B * B - 4.0 * A * C;
  if (disc > 0.0) {
    let sqrt_d = sqrt(disc);
    let t0 = (-B - sqrt_d) / (2.0 * A);
    let t1 = (-B + sqrt_d) / (2.0 * A);
    
    for (var i = 0; i < 2; i++) {
      let t = array<f32, 2>(t0, t1)[i];
      let y = r.origin.y + t * r.direction.y;
      if (t > 0.001 && t < t_min && y >= 0.0 && y <= h) {
        t_min = t;
        let p = r.origin + t * r.direction;
        // Normal is slanted based on the cone angle
        let slant = -k * (r0 + k * y);
        *n_out = normalize(vec3f(p.x, slant, p.z));
        *uv_out = vec2f(atan2(p.z, p.x) / TWO_PI + 0.5, y);
        hit = true;
      }
    }
  }

  // 2. Check Caps (Top at y=1, Bottom at y=0)
  let caps = array<f32, 2>(0.0, 1.0);
  let radii = array<f32, 2>(r0, r1);
  for (var i = 0; i < 2; i++) {
    let py = caps[i];
    let t = (py - r.origin.y) / r.direction.y;
    if (t > 0.001 && t < t_min) {
      let p = r.origin + t * r.direction;
      if (p.x * p.x + p.z * p.z <= radii[i] * radii[i]) {
        t_min = t;
        *n_out = vec3f(0.0, f32(i) * 2.0 - 1.0, 0.0);
        *uv_out = (p.xz / (max(r0, r1) * 2.0)) + 0.5;
        hit = true;
      }
    }
  }

  if (hit) { *t_out = t_min; }
  return hit;
}

fn hit_torus(r: Ray, Ra: f32, ra: f32) -> f32 {
  var po = 1.0;
  
  let Ra2 = Ra * Ra;
  let ra2 = ra * ra;
  
  let m = dot(r.origin, r.origin);
  let n = dot(r.origin, r.direction);

  // 1. Bounding sphere early exit
  let bounds_radius = Ra + ra;
  let h_bound = n * n - m + bounds_radius * bounds_radius;
  if (h_bound < 0.0) { return -1.0; }
  
  // 2. Compute Quartic Coefficients
  // We use r.origin.y and r.direction.y because your shader treats Y as UP
  let k = (m - ra2 - Ra2) / 2.0;
  let k3 = n;
  let k2 = n * n + Ra2 * r.direction.y * r.direction.y + k;
  let k1 = k * n + Ra2 * r.origin.y * r.direction.y;
  let k0 = k * k + Ra2 * r.origin.y * r.origin.y - Ra2 * ra2;
  
  // Numerical stability: handle cases where k1 is near zero by reciprocal transformation
  var K3 = k3; var K2 = k2; var K1 = k1; var K0 = k0;
  if (abs(k3 * (k3 * k3 - k2) + k1) < 0.01) {
    po = -1.0;
    let inv_k0 = 1.0 / k0;
    K1 = k3 * inv_k0;
    K2 = k2 * inv_k0;
    K3 = k1 * inv_k0;
    K0 = inv_k0;
  }

  let c2 = (2.0 * K2 - 3.0 * K3 * K3) / 3.0;
  let c1 = 2.0 * (K3 * (K3 * K3 - K2) + K1);
  let c0 = (K3 * (K3 * (-3.0 * K3 * K3 + 4.0 * K2) - 8.0 * K1) + 4.0 * K0) / 3.0;
  
  let Q = c2 * c2 + c0;
  let R = 3.0 * c0 * c2 - c2 * c2 * c2 - c1 * c1;
  
  let h = R * R - Q * Q * Q;
  var z = 0.0;
  
  if (h < 0.0) {
    // 4 real intersections
    let sQ = sqrt(Q);
    z = 2.0 * sQ * cos(acos(clamp(R / (sQ * Q), -1.0, 1.0)) / 3.0);
  } else {
    // 2 real intersections
    let sQ = pow(sqrt(h) + abs(R), 1.0/3.0);
    z = sign(R) * abs(sQ + Q / sQ);
  }     
  z = c2 - z;
  
  var d1 = z - 3.0 * c2;
  var d2 = z * z - 3.0 * c0;
  
  if (abs(d1) < 1.0e-4) {
    if (d2 < 0.0) { return -1.0; }
    d2 = sqrt(d2);
  } else {
    if (d1 < 0.0) { return -1.0; }
    d1 = sqrt(d1 / 2.0);
    d2 = c1 / d1;
  }

  // 3. Solve the two quadratics
  var result = 1e20;

  // First quadratic
  var h1 = d1 * d1 - z + d2;
  if (h1 > 0.0) {
    h1 = sqrt(h1);
    var t1 = -d1 - h1 - K3; if(po < 0.0){ t1 = 2.0/t1; }
    var t2 = -d1 + h1 - K3; if(po < 0.0){ t2 = 2.0/t2; }
    if (t1 > 0.001) { result = t1; }
    if (t2 > 0.001) { result = min(result, t2); }
  }

  // Second quadratic
  var h2 = d1 * d1 - z - d2;
  if (h2 > 0.0) {
    h2 = sqrt(h2);
    var t3 = d1 - h2 - K3; if(po < 0.0){ t3 = 2.0/t3; }
    var t4 = d1 + h2 - K3; if(po < 0.0){ t4 = 2.0/t4; }
    if (t3 > 0.001) { result = min(result, t3); }
    if (t4 > 0.001) { result = min(result, t4); }
  }

  return select(result, -1.0, result > 1e10);
}

fn trace_mesh(ray_world: Ray, mesh: MeshInstance, hit: ptr<function, SurfaceHit>, idx: i32) {
  // Transform ray into local space. Do not normalize direction to keep t identical!
  var ray_local: Ray;
  ray_local.origin = (mesh.inv_matrix * vec4f(ray_world.origin, 1.0)).xyz;
  ray_local.direction = (mesh.inv_matrix * vec4f(ray_world.direction, 0.0)).xyz;
  
  let inv_dir = 1.0 / ray_local.direction;
  var stack: array<u32, STACK_SIZE>; 
  var stack_ptr: i32 = 0;
  
  stack[0] = mesh.node_offset; // Start at root node for this mesh
  stack_ptr++;
  let base_t = intersect_aabb(ray_local.origin, inv_dir, bvh_nodes[mesh.node_offset].aabb_min, bvh_nodes[mesh.node_offset].aabb_max);
  if (base_t < 0. || base_t >= (*hit).t) {return;}

  while (stack_ptr > 0) {
    (*hit).count++;
    stack_ptr--;
    let node_idx = stack[stack_ptr];
    let node = bvh_nodes[node_idx];

    //let t_aabb = intersect_aabb(ray_local.origin, inv_dir, node.aabb_min, node.aabb_max);
    //if (t_aabb < 0. || t_aabb >= (*hit).t) { continue; }

    if (node.num_triangles > 0u) {
      // Leaf
      let start = mesh.tri_offset + node.next;
      let end = start + node.num_triangles;
      for (var i = start; i < end; i++) {
        let tri = triangles[i];
        var t_tri = 0.0;
        var uv_tri = vec2f(0.0);
        var bary = vec3f(0.0);
        
        if (intersect_triangle(ray_local, tri, &t_tri, &uv_tri, &bary)) {
          if (t_tri >= 0 && t_tri < (*hit).t) {
            (*hit).t = t_tri;
            (*hit).m_idx = mesh.material_idx;
            
            // Need local hit and normal, transform back to world space
            let local_hit = ray_local.origin + ray_local.direction * t_tri;
            let local_norm = normalize(tri.n0 * bary.x + tri.n1 * bary.y + tri.n2 * bary.z);
            
            (*hit).hit_p = ray_world.origin + ray_world.direction * t_tri;
            
            // Transform normal: transpose of inverse (which is just inv_matrix transposed)
            // Inverse transpose is used for normals when non-uniform scaling occurs
            let world_norm = transpose(mesh.inv_matrix) * vec4f(local_norm, 0.0);
            (*hit).hit_n = normalize(world_norm.xyz);
            (*hit).hit_uv = uv_tri;
            (*hit).o_idx = idx;
          }
        }
      }
    } else {
      // Inner Node
      let left_idx = node_idx + 1u;
      let right_idx = mesh.node_offset + node.next;
      let left_t = intersect_aabb(ray_local.origin, inv_dir, bvh_nodes[left_idx].aabb_min, bvh_nodes[left_idx].aabb_max);
      let right_t = intersect_aabb(ray_local.origin, inv_dir, bvh_nodes[right_idx].aabb_min, bvh_nodes[right_idx].aabb_max);
      if (left_t < right_t) {
        if (right_t >= 0. && right_t < (*hit).t) { stack[stack_ptr] = right_idx; stack_ptr++; }
        if (left_t >= 0. && left_t < (*hit).t) { stack[stack_ptr] = left_idx; stack_ptr++; }
      } else {
        if (left_t >= 0. && left_t < (*hit).t) { stack[stack_ptr] = left_idx; stack_ptr++; }
        if (right_t >= 0. && right_t < (*hit).t) { stack[stack_ptr] = right_idx; stack_ptr++; }
      }
    }
  }
}

fn trace_sphere(ray_world: Ray, s: TransformedObject, hit: ptr<function, SurfaceHit>, idx: i32) {
  var local_ray: Ray;
  local_ray.origin = (s.inv_matrix * vec4f(ray_world.origin, 1.0)).xyz;
  local_ray.direction = (s.inv_matrix * vec4f(ray_world.direction, 0.0)).xyz;
  
  let t = hit_unit_sphere(local_ray);
  if (t > 0.001 && t < (*hit).t) {
    (*hit).t = t; 
    (*hit).m_idx = s.material_idx;
    
    let local_normal = local_ray.origin + local_ray.direction * t;
    
    // UV Mapping
    let phi = atan2(local_normal.z, local_normal.x);
    let theta = asin(clamp(local_normal.y, -1.0, 1.0));
    (*hit).hit_uv = vec2f(0.5 + phi / TWO_PI, 0.5 + theta / PI);
    
    // Tangent Basis
    var local_t = vec3f(-local_normal.z, 0.0, local_normal.x);
    if (abs(local_normal.y) > 0.9999) { local_t = vec3f(1.0, 0.0, 0.0); }
    local_t = normalize(local_t);
    let local_b = cross(local_normal, local_t);
    
    // Transform to World Space
    let n_mat = transpose(mat3x3f(s.inv_matrix[0].xyz, s.inv_matrix[1].xyz, s.inv_matrix[2].xyz));
    (*hit).hit_n = normalize(n_mat * local_normal);
    (*hit).tangent = normalize(n_mat * local_t);
    (*hit).bitangent = normalize(n_mat * local_b);
    (*hit).hit_p = ray_world.origin + ray_world.direction * t;
    (*hit).o_idx = idx;
  }
}

fn trace_cube(ray_world: Ray, c: TransformedObject, hit: ptr<function, SurfaceHit>, idx: i32) {
  var local_ray: Ray;
  local_ray.origin = (c.inv_matrix * vec4f(ray_world.origin, 1.0)).xyz;
  local_ray.direction = (c.inv_matrix * vec4f(ray_world.direction, 0.0)).xyz;
  
  let t = hit_unit_cube(local_ray);
  if (t > 0.001 && t < (*hit).t) {
    (*hit).t = t; 
    (*hit).m_idx = c.material_idx;
    
    let local_hit = local_ray.origin + local_ray.direction * t;
    let d = abs(local_hit);
    let max_d = max_component(d);

    var local_n: vec3f; var local_t: vec3f; var local_b: vec3f;

    if (max_d == d.x) { 
      let s = sign(local_hit.x);
      local_n = vec3f(s, 0.0, 0.0);
      local_t = vec3f(0.0, 0.0, -s); 
      local_b = vec3f(0.0, 1.0, 0.0);
      (*hit).hit_uv = vec2f(-s * local_hit.z, local_hit.y) * 0.5 + 0.5;
    } else if (max_d == d.y) { 
      let s = sign(local_hit.y);
      local_n = vec3f(0.0, s, 0.0);
      local_t = vec3f(1.0, 0.0, 0.0); 
      local_b = vec3f(0.0, 0.0, s);
      (*hit).hit_uv = vec2f(local_hit.x, s * local_hit.z) * 0.5 + 0.5;
    } else { 
      let s = sign(local_hit.z);
      local_n = vec3f(0.0, 0.0, s);
      local_t = vec3f(s, 0.0, 0.0); 
      local_b = vec3f(0.0, 1.0, 0.0);
      (*hit).hit_uv = vec2f(s * local_hit.x, local_hit.y) * 0.5 + 0.5;
    }

    let n_mat = transpose(mat3x3f(c.inv_matrix[0].xyz, c.inv_matrix[1].xyz, c.inv_matrix[2].xyz));
    (*hit).hit_n = normalize(n_mat * local_n);
    (*hit).tangent = normalize(n_mat * local_t);
    (*hit).bitangent = normalize(n_mat * local_b);
    (*hit).hit_p = ray_world.origin + ray_world.direction * t;
    (*hit).o_idx = idx;
  }
}

fn trace_plane(ray_world: Ray, p: Plane, hit: ptr<function, SurfaceHit>) {
  let t = hit_plane(p.normal, p.d, ray_world);
  if (t > 0.001 && t < (*hit).t) {
    (*hit).t = t; 
    (*hit).m_idx = p.material_idx;
    (*hit).hit_n = p.normal;
    (*hit).hit_p = ray_world.origin + ray_world.direction * t;
    
    var tangent = vec3f(1.0, 0.0, 0.0);
    if (abs((*hit).hit_n.x) > 0.9) { tangent = vec3f(0.0, 0.0, 1.0); }
    (*hit).tangent = normalize(cross((*hit).hit_n, tangent));
    (*hit).bitangent = normalize(cross((*hit).hit_n, (*hit).tangent));
    (*hit).hit_uv = vec2f(dot((*hit).hit_p, (*hit).tangent), dot((*hit).hit_p, (*hit).bitangent));
  }
}

fn trace_cylinder(ray_world: Ray, f: Cylinder, hit: ptr<function, SurfaceHit>, idx: i32) {
  var local_ray: Ray;
  local_ray.origin = (f.inv_matrix * vec4f(ray_world.origin, 1.0)).xyz;
  local_ray.direction = (f.inv_matrix * vec4f(ray_world.direction, 0.0)).xyz;

  var t: f32; var n: vec3f; var uv: vec2f;
  if (hit_cylinder(local_ray, 1.0, f.top_radius, &t, &n, &uv)) {
    if (t < (*hit).t) {
      (*hit).t = t;
      (*hit).m_idx = f.material_idx;
      (*hit).hit_uv = uv;
      
      let n_mat = transpose(mat3x3f(f.inv_matrix[0].xyz, f.inv_matrix[1].xyz, f.inv_matrix[2].xyz));
      (*hit).hit_n = normalize(n_mat * n);
      (*hit).hit_p = ray_world.origin + ray_world.direction * t;
      (*hit).o_idx = idx;
    }
  }
}

fn trace_torus(ray: Ray, tor: Torus, hit: ptr<function, SurfaceHit>, idx: i32) {
  var l_ray: Ray;
  l_ray.origin = (tor.inv_matrix * vec4f(ray.origin, 1.0)).xyz;
  l_ray.direction = (tor.inv_matrix * vec4f(ray.direction, 0.0)).xyz;
  
  let ray_scale = length(l_ray.direction);
  l_ray.direction /= ray_scale; 

  // Major radius is 1.0 in local space, inner_radius is tor.inner_radius
  let t = hit_torus(l_ray, 1.0, tor.inner_radius * 1.);

  if (t > 0.) {
    let world_t = t / ray_scale;
    if (world_t < (*hit).t) {
      (*hit).t = world_t;
      (*hit).m_idx = tor.material_idx;
      
      let p = l_ray.origin + l_ray.direction * t;

      // 3. Normal logic: Point p minus the closest point on the center-ring
      let ring_p = normalize(vec3f(p.x, 0.0, p.z)); 
      let local_n = normalize(p - ring_p);
      
      let n_mat = mat3x3f(tor.inv_matrix[0].xyz, tor.inv_matrix[1].xyz, tor.inv_matrix[2].xyz);
      (*hit).hit_n = normalize(n_mat * local_n);

      // 4. UVs
      let u = (atan2(p.z, p.x) / TWO_PI) + 0.5;
      let v = (atan2(p.y, length(p.xz) - 1.0) / TWO_PI) + 0.5;
      (*hit).hit_uv = vec2f(u, v);

      (*hit).o_idx = idx;
    }
  }
}

fn trace_tlas(ray: Ray, hit: ptr<function, SurfaceHit>) {
  let inv_dir = 1.0 / ray.direction;

  var stack: array<u32, STACK_SIZE>; 
  var stack_ptr: i32 = 0;
  
  stack[0] = 0;
  stack_ptr++;
  let base_t = intersect_aabb(ray.origin, inv_dir, tlas_nodes[0].aabb_min, tlas_nodes[0].aabb_max);
  if (base_t < 0. || base_t >= (*hit).t) {return;}

  while (stack_ptr > 0) {
    (*hit).count++;
    stack_ptr--;
    let node_idx = stack[stack_ptr];
    let node = tlas_nodes[node_idx];

    //let t_aabb = intersect_aabb(ray.origin, inv_dir, node.aabb_min, node.aabb_max);
    //if (t_aabb < 0. || t_aabb >= (*hit).t) { continue; }

    if (node.num_triangles > 0u) {
      // Leaf
      let start = node.next;
      let end = start + node.num_triangles;
      for (var i = start; i < end; i++) {
        let obj = objects[i];
        let otype = obj.object_type;
        let idx = i32(i);
        if (HAS_MESHES && otype == 0) {
          let mesh = MeshInstance(obj.inv_matrix,obj.material_idx,0,bitcast<u32>(obj.param0),bitcast<u32>(obj.param1));
          trace_mesh(ray, mesh, hit, idx);
        } else if (HAS_SPHERES && otype == 1) { 
          trace_sphere(ray, obj, hit, idx);
        } else if (HAS_CUBES && otype == 2) { 
          trace_cube(ray, obj, hit, idx);
        } else if (HAS_CYLINDERS && otype == 3) { 
          let cylinder = Cylinder(obj.inv_matrix,obj.material_idx,obj.param0);
          trace_cylinder(ray, cylinder, hit, idx);
        } else if (HAS_TORI && otype == 4) {
          let torus = Torus(obj.inv_matrix,obj.material_idx,obj.param0);
          trace_torus(ray, torus, hit, idx);
        }
      }
    } else {
      // Inner Node
      let left_idx = node_idx + 1u;
      let right_idx = node.next;
      let left_t = intersect_aabb(ray.origin, inv_dir, tlas_nodes[left_idx].aabb_min, tlas_nodes[left_idx].aabb_max);
      let right_t = intersect_aabb(ray.origin, inv_dir, tlas_nodes[right_idx].aabb_min, tlas_nodes[right_idx].aabb_max);
      if (left_t < right_t) {
        if (right_t >= 0. && right_t < (*hit).t) { stack[stack_ptr] = right_idx; stack_ptr++; }
        if (left_t >= 0. && left_t < (*hit).t) { stack[stack_ptr] = left_idx; stack_ptr++; }
      } else {
        if (left_t >= 0. && left_t < (*hit).t) { stack[stack_ptr] = left_idx; stack_ptr++; }
        if (right_t >= 0. && right_t < (*hit).t) { stack[stack_ptr] = right_idx; stack_ptr++; }
      }
    }
  }
}

fn trace_scene(ray: Ray) -> SurfaceHit {
  var hit = SurfaceHit(1e10, -1, vec3f(0.0), vec3f(0.0), vec2f(0.0), vec3f(0.0), vec3f(0.0), -1, 0);
  
  if (HAS_PLANES) {
    for (var i = 0u; i < arrayLength(&planes); i++) {
      trace_plane(ray, planes[i], &hit);
    }
  }

  if (HAS_SPHERES || HAS_CUBES || HAS_CYLINDERS || HAS_TORI || HAS_MESHES) {
    trace_tlas(ray, &hit);
  }

  if (HAS_LIST_MESHES) {
    for (var i = 0u; i < arrayLength(&meshes); i++) {
      trace_mesh(ray, meshes[i], &hit, -1);
    }
  }

  return hit;
}

// Helper to evaluate shadow attenuation for a material
fn evaluate_shadow_attenuation(mat: Material, hit_uv: vec2f, dist: f32, shadow: ptr<function, vec3f>) -> bool {
  //if (mat.transmission <= 0.0 && mat.albedo_idx < 0) {
  //  *shadow = vec3f(0.0);
  //  return true;
  //}

  //var albedo = mat.color;
  if (mat.albedo_idx >= 0) {
    let tex_color = sample_texture(mat.albedo_idx, hit_uv * mat.uv_scale);
    //albedo *= tex_color.rgb;
    // Apply alpha transparency (1.0 - alpha)
    *shadow *= (1.0 - tex_color.a);
    if (tex_color.a > 0.9999) { return true; }
  } else {
    return true;
  }

  // Beer's Law for internal absorption if IOR is ~1.0 (thin glass approximation)
  // or if the material is explicitly transmissive.
  //if (mat.transmission > 0.0 && mat.ior <= 1.05 && dist > 0) {
  //  let sigma = -log(max(mat.color, vec3f(0.0001))) * mat.concentration;
  //  let attenuation = exp(-sigma * dist);
  //  *shadow *= attenuation;
  //}

  // Clear coat reflection loss
  //if (mat.clearcoat > 0.0) {
  //  // Approximate clearcoat reflection loss (Schlick)
  //  let R0 = pow((1.0 - mat.clearcoat_ior) / (1.0 + mat.clearcoat_ior), 2.0);
  //  // We assume near-normal incidence for the shadow ray for simplicity, //  // or we could use the actual L vector.
  //  let reflection = R0 + (1.0 - R0) * 0.1; // 0.1 is a placeholder for (1-cos)^5
  //  *shadow *= (1.0 - mat.clearcoat * reflection);
  //}
  return false;
}

fn trace_mesh_shadow(ray_world: Ray, mesh: MeshInstance, target_dist: f32, shadow: ptr<function, vec3f>) -> bool {
  var ray_local: Ray;
  ray_local.origin = (mesh.inv_matrix * vec4f(ray_world.origin, 1.0)).xyz;
  ray_local.direction = (mesh.inv_matrix * vec4f(ray_world.direction, 0.0)).xyz;
  let inv_dir = 1.0 / ray_local.direction;

  var stack: array<u32, STACK_SIZE>;
  var stack_ptr: i32 = 0;
  stack[0] = mesh.node_offset;
  stack_ptr++;

  // Initial AABB check
  let base_t = intersect_aabb(ray_local.origin, inv_dir, bvh_nodes[mesh.node_offset].aabb_min, bvh_nodes[mesh.node_offset].aabb_max);
  if (base_t < 0. || base_t >= target_dist) { return false; }

  var last_t = 0.0;
  var is_inside = false;
  let mat = materials[mesh.material_idx];

  while (stack_ptr > 0) {
    stack_ptr--;
    let node_idx = stack[stack_ptr];
    let node = bvh_nodes[node_idx];

    if (node.num_triangles > 0u) {
      let start = mesh.tri_offset + node.next;
      let end = start + node.num_triangles;

      for (var i = start; i < end; i++) {
        let tri = triangles[i];
        var t_tri = 0.0;
        var uv_tri = vec2f(0.0);
        var bary = vec3f(0.0);

        if (intersect_triangle(ray_local, tri, &t_tri, &uv_tri, &bary)) {
          if (t_tri >= 0 && t_tri < target_dist) {
            let volume_dist = select(0, t_tri - last_t, is_inside);
            if (evaluate_shadow_attenuation(mat, uv_tri, volume_dist, shadow)) { return true; }
            last_t = t_tri;
            is_inside = !is_inside;
          }
        }
      }
    } else {
      let left_idx = node_idx + 1u;
      let right_idx = mesh.node_offset + node.next;
      let left_t = intersect_aabb(ray_local.origin, inv_dir, bvh_nodes[left_idx].aabb_min, bvh_nodes[left_idx].aabb_max);
      let right_t = intersect_aabb(ray_local.origin, inv_dir, bvh_nodes[right_idx].aabb_min, bvh_nodes[right_idx].aabb_max);

      if (left_t < right_t) {
        if (right_t >= 0. && right_t < target_dist) { stack[stack_ptr] = right_idx; stack_ptr++; }
        if (left_t >= 0. && left_t < target_dist) { stack[stack_ptr] = left_idx; stack_ptr++; }
      } else {
        if (left_t >= 0. && left_t < target_dist) { stack[stack_ptr] = left_idx; stack_ptr++; }
        if (right_t >= 0. && right_t < target_dist) { stack[stack_ptr] = right_idx; stack_ptr++; }
      }
    }
  }
  return false;
}

fn trace_sphere_shadow(ray_world: Ray, s: TransformedObject, target_dist: f32, shadow: ptr<function, vec3f>) -> bool {
  var local_ray: Ray;
  local_ray.origin = (s.inv_matrix * vec4f(ray_world.origin, 1.0)).xyz;
  local_ray.direction = (s.inv_matrix * vec4f(ray_world.direction, 0.0)).xyz;

  let a = dot(local_ray.direction, local_ray.direction);
  let half_b = dot(local_ray.origin, local_ray.direction);
  let c = dot(local_ray.origin, local_ray.origin) - 1.0;
  let disc = half_b * half_b - a * c;

  if (disc < 0.0) { return false; }
  let sqrtd = sqrt(disc);
  let t1 = (-half_b - sqrtd) / a;
  let t2 = (-half_b + sqrtd) / a;

  let h1 = max(0.001, t1);
  let h2 = min(target_dist, t2);

  if (h1 < h2) {
    let mat = materials[s.material_idx];
    // 1. Entry surface
    let p1 = local_ray.origin + local_ray.direction * h1;
    let uv1 = vec2f(0.5 + atan2(p1.z, p1.x) / TWO_PI, 0.5 + asin(clamp(p1.y, -1.0, 1.0)) / PI);
    if (evaluate_shadow_attenuation(mat, uv1, 0.0, shadow)) { return true; }

    // 2. Exit surface & Internal Volume
    let p2 = local_ray.origin + local_ray.direction * h2;
    let uv2 = vec2f(0.5 + atan2(p2.z, p2.x) / TWO_PI, 0.5 + asin(clamp(p2.y, -1.0, 1.0)) / PI);
    return evaluate_shadow_attenuation(mat, uv2, h2 - h1, shadow);
  }
  return false;
}

fn get_cube_uv(local_hit: vec3f) -> vec2f {
  let d = abs(local_hit);
  let max_d = max_component(d);
  var uv: vec2f;

  if (max_d == d.x) {
    let s = sign(local_hit.x);
    uv = vec2f(-s * local_hit.z, local_hit.y) * 0.5 + 0.5;
  } else if (max_d == d.y) {
    let s = sign(local_hit.y);
    uv = vec2f(local_hit.x, s * local_hit.z) * 0.5 + 0.5;
  } else {
    let s = sign(local_hit.z);
    uv = vec2f(s * local_hit.x, local_hit.y) * 0.5 + 0.5;
  }
  
  return uv;
}

fn trace_cube_shadow(ray_world: Ray, c: TransformedObject, target_dist: f32, shadow: ptr<function, vec3f>) -> bool {
  var local_ray: Ray;
  local_ray.origin = (c.inv_matrix * vec4f(ray_world.origin, 1.0)).xyz;
  local_ray.direction = (c.inv_matrix * vec4f(ray_world.direction, 0.0)).xyz;

  let inv_dir = 1.0 / local_ray.direction;
  let t_near_xyz = (-1.0 - local_ray.origin) * inv_dir;
  let t_far_xyz = (1.0 - local_ray.origin) * inv_dir;
  let t_min = min(t_near_xyz, t_far_xyz);
  let t_max = max(t_near_xyz, t_far_xyz);

  let t1 = max_component(t_min);
  let t2 = min_component(t_max);

  let h1 = max(0.001, t1);
  let h2 = min(target_dist, t2);

  if (h1 < h2) {
    let mat = materials[c.material_idx];
    // 1. Entry surface
    let p1 = local_ray.origin + local_ray.direction * h1;
    let uv1 = get_cube_uv(p1); // Use your existing cube UV logic here
    if (evaluate_shadow_attenuation(mat, uv1, 0.0, shadow)) { return true; }

    // 2. Exit surface & Internal Volume
    let p2 = local_ray.origin + local_ray.direction * h2;
    let uv2 = get_cube_uv(p2);
    return evaluate_shadow_attenuation(mat, uv2, h2 - h1, shadow);
  }
  return false;
}

fn get_frustum_uv(p: vec3f, r0: f32, r1: f32) -> vec2f {
  if (p.y > 0.999) { return (p.xz / (r1 * 2.0)) + 0.5; } // Top
  if (p.y < 0.001) { return (p.xz / (r0 * 2.0)) + 0.5; } // Bottom
  return vec2f(atan2(p.z, p.x) / TWO_PI + 0.5, p.y);      // Side
}

fn trace_cylinder_shadow(ray_world: Ray, f: Cylinder, target_dist: f32, shadow: ptr<function, vec3f>) -> bool {
  var r: Ray;
  r.origin = (f.inv_matrix * vec4f(ray_world.origin, 1.0)).xyz;
  r.direction = (f.inv_matrix * vec4f(ray_world.direction, 0.0)).xyz;

  let k = (f.top_radius - 1.0) / 1.0; // r0 is 1.0, h is 1.0
  let origin_eff_r = 1.0 + k * r.origin.y;
  
  let A = r.direction.x * r.direction.x + r.direction.z * r.direction.z - k * k * r.direction.y * r.direction.y;
  let B = 2.0 * (r.origin.x * r.direction.x + r.origin.z * r.direction.z - origin_eff_r * k * r.direction.y);
  let C = r.origin.x * r.origin.x + r.origin.z * r.origin.z - origin_eff_r * origin_eff_r;

  var h1 = 1e10; var h2 = -1e10;
  var hit_count = 0u;

  // Side Hits
  let disc = B * B - 4.0 * A * C;
  if (disc >= 0.0) {
    let sqrt_d = sqrt(disc);
    let ts = vec2f((-B - sqrt_d) / (2.0 * A), (-B + sqrt_d) / (2.0 * A));
    for (var i = 0; i < 2; i++) {
      let t = ts[i];
      let y = r.origin.y + t * r.direction.y;
      if (y >= 0.0 && y <= 1.0) {
        h1 = min(h1, t); h2 = max(h2, t); hit_count++;
      }
    }
  }

  // Cap Hits
  let caps = vec2f(0.0, 1.0);
  let radii = vec2f(1.0, f.top_radius);
  for (var i = 0; i < 2; i++) {
    let t = (caps[i] - r.origin.y) / r.direction.y;
    let p = r.origin + t * r.direction;
    if (p.x * p.x + p.z * p.z <= radii[i] * radii[i]) {
      h1 = min(h1, t); h2 = max(h2, t); hit_count++;
    }
  }

  if (hit_count >= 2u) {
    let final_h1 = max(0.001, h1);
    let final_h2 = min(target_dist, h2);
    if (final_h1 < final_h2) {
      let mat = materials[f.material_idx];
      let uv1 = get_frustum_uv(r.origin + r.direction * final_h1, 1.0, f.top_radius);
      if (evaluate_shadow_attenuation(mat, uv1, 0.0, shadow)) { return true; }
      let uv2 = get_frustum_uv(r.origin + r.direction * final_h2, 1.0, f.top_radius);
      return evaluate_shadow_attenuation(mat, uv2, final_h2 - final_h1, shadow);
    }
  }
  return false;
}

// Helper: Solves t^3 + at^2 + bt + c = 0
fn solve_cubic_real(a: f32, b: f32, c: f32) -> f32 {
  let q = (a * a - 3.0 * b) / 9.0;
  let r = (2.0 * a * a * a - 9.0 * a * b + 27.0 * c) / 54.0;
  let r2 = r * r;
  let q3 = q * q * q;

  if (r2 < q3) {
    let theta = acos(clamp(r / sqrt(q3), -1.0, 1.0));
    return -2.0 * sqrt(q) * cos(theta / 3.0) - a / 3.0;
  } else {
    let aa = -sign(r) * pow(abs(r) + sqrt(r2 - q3), 1.0/3.0);
    var bb = 0.0;
    if (aa != 0.0) { bb = q / aa; }
    return (aa + bb) - a / 3.0;
  }
}

// Main Solver: t^4 + at^3 + bt^2 + ct + d = 0
fn solve_quartic_real(a: f32, b: f32, c: f32, d: f32) -> array<f32, 4> {
  var roots = array<f32, 4>(-1.0, -1.0, -1.0, -1.0);
  var count = 0u;

  // 1. Resolve cubic: y^3 - b*y^2 + (ac - 4d)*y - (a^2*d + c^2 - 4bd) = 0
  let a2 = a * a;
  let y = solve_cubic_real(-b, a * c - 4.0 * d, 4.0 * b * d - a2 * d - c * c);

  // 2. Derive quadratic coefficients
  let R2 = 0.25 * a2 - b + y;
  if (R2 < 0.0) { return roots; }
  let R = sqrt(R2);

  var D2: f32;
  var E2: f32;

  if (R < 1e-6) {
    D2 = 0.75 * a2 - 2.0 * b + 2.0 * sqrt(y * y - 4.0 * d);
    E2 = 0.75 * a2 - 2.0 * b - 2.0 * sqrt(y * y - 4.0 * d);
  } else {
    D2 = 0.75 * a2 - R2 - 2.0 * b + (4.0 * a * b - 8.0 * c - a2 * a) / (4.0 * R);
    E2 = 0.75 * a2 - R2 - 2.0 * b - (4.0 * a * b - 8.0 * c - a2 * a) / (4.0 * R);
  }

  // 3. Solve the two quadratics
  if (D2 >= 0.0) {
    let D = sqrt(D2);
    roots[0] = -0.25 * a + 0.5 * R + 0.5 * D;
    roots[1] = -0.25 * a + 0.5 * R - 0.5 * D;
    count += 2u;
  }
  if (E2 >= 0.0) {
    let E = sqrt(E2);
    roots[count] = -0.25 * a - 0.5 * R + 0.5 * E;
    roots[count + 1u] = -0.25 * a - 0.5 * R - 0.5 * E;
    count += 2u;
  }

  // 4. Sort roots (Bubble sort for small fixed array)
  for (var i = 0u; i < 3u; i++) {
    for (var j = i + 1u; j < 4u; j++) {
      if (roots[i] > roots[j]) {
        let temp = roots[i];
        roots[i] = roots[j];
        roots[j] = temp;
      }
    }
  }

  return roots;
}


fn get_torus_uv(p: vec3f) -> vec2f {
  let u = (atan2(p.z, p.x) / TWO_PI) + 0.5;
  let v = (atan2(p.y, length(p.xz) - 1.0) / TWO_PI) + 0.5;
  return vec2f(u, v);
}

fn trace_torus_shadow(ray_world: Ray, tor: Torus, target_dist: f32, shadow: ptr<function, vec3f>) -> bool {
  var l_r: Ray;
  l_r.origin = (tor.inv_matrix * vec4f(ray_world.origin, 1.0)).xyz;
  l_r.direction = (tor.inv_matrix * vec4f(ray_world.direction, 0.0)).xyz;
  let ray_scale = length(l_r.direction);
  l_r.direction /= ray_scale;

  let R = 1.0; let r = tor.inner_radius;
  let K = dot(l_r.origin, l_r.origin) + R*R - r*r;
  let G = dot(l_r.origin, l_r.direction);

  // quartic: t^4 + Bt^3 + Ct^2 + Dt + E = 0
  let B = 4.0 * G;
  let C = 2.0 * K + 4.0 * G * G - 4.0 * R * R * (1.0 - l_r.direction.y * l_r.direction.y);
  let D = 4.0 * K * G - 8.0 * R * R * l_r.origin.y * l_r.direction.y;
  let E = K * K - 4.0 * R * R * (l_r.origin.x * l_r.origin.x + l_r.origin.z * l_r.origin.z);

  let roots = solve_quartic_real(B, C, D, E); // Assume helper returns sorted array<f32, 4>
  let mat = materials[tor.material_idx];

  // Check intervals: [root[0], root[1]] and [root[2], root[3]]
  for (var i = 0; i < 4; i += 2) {
    let t_near = roots[i]; let t_far = roots[i+1];
    if (t_near < 0.0 || t_near > target_dist * ray_scale) { continue; }
    
    let h1 = max(0.001, t_near) / ray_scale;
    let h2 = min(target_dist * ray_scale, t_far) / ray_scale;
    
    if (h1 < h2) {
      let uv1 = get_torus_uv(l_r.origin + l_r.direction * (h1 * ray_scale));
      if (evaluate_shadow_attenuation(mat, uv1, 0.0, shadow)) { return true; }
      let uv2 = get_torus_uv(l_r.origin + l_r.direction * (h2 * ray_scale));
      if (evaluate_shadow_attenuation(mat, uv2, h2 - h1, shadow)) { return true; }
    }
  }
  return false;
}

fn trace_tlas_shadow(ray: Ray, target_idx: i32, target_dist: f32, shadow: ptr<function, vec3f>) -> bool {
  let inv_dir = 1.0 / ray.direction;
  var stack: array<u32, STACK_SIZE>;
  var stack_ptr: i32 = 0;
  stack[stack_ptr] = 0u;
  stack_ptr++;

  while (stack_ptr > 0) {
    stack_ptr--;
    let node_idx = stack[stack_ptr];
    let node = tlas_nodes[node_idx];

    if (node.num_triangles > 0u) {
      let start = node.next;
      let end = start + node.num_triangles;
      for (var i = start; i < end; i++) {
        if (i32(i) == target_idx) { continue; }
        let obj = objects[i];
        let otype = obj.object_type;
        if (HAS_MESHES && otype == 0) {
          let mesh = MeshInstance(obj.inv_matrix,obj.material_idx,0,bitcast<u32>(obj.param0),bitcast<u32>(obj.param1));
          if (trace_mesh_shadow(ray, mesh, target_dist, shadow)) { return true; }
        } else if (HAS_SPHERES && otype == 1) {
          if (trace_sphere_shadow(ray, obj, target_dist, shadow)) { return true; }
        } else if (HAS_CUBES && otype == 2) {
          if (trace_cube_shadow(ray, obj, target_dist, shadow)) { return true; }
        } else if (HAS_CYLINDERS && otype == 3) {
          let cylinder = Cylinder(obj.inv_matrix,obj.material_idx,obj.param0);
          if (trace_cylinder_shadow(ray, cylinder, target_dist, shadow)) { return true; }
        } else if (HAS_TORI && otype == 4) {
          let torus = Torus(obj.inv_matrix,obj.material_idx,obj.param0);
          if (trace_torus_shadow(ray, torus, target_dist, shadow)) { return true; }
        }
      }
    } else {
      let left_idx = node_idx + 1u;
      let right_idx = node.next;
      let left_t = intersect_aabb(ray.origin, inv_dir, tlas_nodes[left_idx].aabb_min, tlas_nodes[left_idx].aabb_max);
      let right_t = intersect_aabb(ray.origin, inv_dir, tlas_nodes[right_idx].aabb_min, tlas_nodes[right_idx].aabb_max);

      if (left_t < right_t) {
        if (right_t >= 0. && right_t < target_dist) { stack[stack_ptr] = right_idx; stack_ptr++; }
        if (left_t >= 0. && left_t < target_dist) { stack[stack_ptr] = left_idx; stack_ptr++; }
      } else {
        if (left_t >= 0. && left_t < target_dist) { stack[stack_ptr] = left_idx; stack_ptr++; }
        if (right_t >= 0. && right_t < target_dist) { stack[stack_ptr] = right_idx; stack_ptr++; }
      }
    }
  }
  return false;
}

fn trace_plane_shadow(ray: Ray, p: Plane, target_dist: f32, shadow: ptr<function, vec3f>) -> bool {
  let denom = dot(p.normal, ray.direction);
  if (abs(denom) > 1e-6) {
    let t = (p.d - dot(p.normal, ray.origin)) / denom;
    if (t > 0.001 && t < target_dist) {
      let hit_pos = ray.origin + ray.direction * t;
      let mat = materials[p.material_idx];
      
      var tangent = vec3f(1.0, 0.0, 0.0);
      if (abs(p.normal.x) > 0.9999) { tangent = vec3f(0.0, 0.0, 1.0); }
      tangent = normalize(cross(p.normal, tangent));
      let bitangent = normalize(cross(p.normal, tangent));
      let uv = vec2f(dot(hit_pos, tangent), dot(hit_pos, bitangent));
      
      return evaluate_shadow_attenuation(mat, uv, length(ray.origin-hit_pos), shadow);
    }
  }
  return false;
}

fn trace_scene_shadow(ray: Ray, target_idx: i32, target_dist: f32) -> vec3f { 
  var shadow = vec3f(1.0);

  // 1. Planes
  if (HAS_PLANES) {
    for (var i = 0u; i < arrayLength(&planes); i++) {
      if (trace_plane_shadow(ray, planes[i], target_dist, &shadow)) { return vec3f(0.0); };
    }
  }

  // 2. TLAS (Spheres, Cubes, etc.)
  if (HAS_SPHERES || HAS_CUBES || HAS_CYLINDERS || HAS_TORI || HAS_MESHES) {
    if (trace_tlas_shadow(ray, target_idx, target_dist, &shadow)) { return vec3f(0.0); }
  }

  // 3. List Meshes (Non-accelerated)
  if (HAS_LIST_MESHES) {
    for (var i = 0u; i < arrayLength(&meshes); i++) {
      if (trace_mesh_shadow(ray, meshes[i], target_dist, &shadow)) { return vec3f(0.0); }
    }
  }

  return shadow;
}

struct PomResult {
  uv: vec2f,
  height: f32,
  hit: bool,
};

// --- PARALLAX OCCLUSION MAPPING FUNCTION ---
fn calculate_pom(initial_uv: vec2f, view_dir_ts: vec3f, start_depth: f32, mat: Material, height_idx: i32) -> PomResult {
  var res: PomResult;
  res.hit = false;
  let hm = mat.height_params.y;
  let is_height_map = hm < 0.0;
  let scale = abs(hm);
  let numLayers = mat.height_params.z;
  var layerDepth = 1.0 / numLayers;
  
  var currentLayerDepth = clamp(start_depth,0.,1.);
  let P = -(view_dir_ts.xy / view_dir_ts.z) * scale;
  let deltaTexCoords = P / numLayers;
  var currentTexCoords = initial_uv - P * mat.height_params.w;

  var s = sample_texture(height_idx, currentTexCoords).r;
  var currentDepthMapValue = select(s, 1.0 - s, is_height_map);

  for (var i: i32 = 0; i < 64; i++) {
    if (f32(i) >= numLayers || currentLayerDepth >= currentDepthMapValue) { break; }
    if (currentLayerDepth > 1 || currentLayerDepth < 0) { return res; }
    currentTexCoords += deltaTexCoords;
    s = sample_texture(height_idx, currentTexCoords).r;
    currentDepthMapValue = select(s, 1.0 - s, is_height_map);
    currentLayerDepth += layerDepth;
  }

  let prevTexCoords = currentTexCoords - deltaTexCoords;
  let prev_s = sample_texture(height_idx, prevTexCoords).r;
  let prevDepthMapValue = select(prev_s, 1.0 - prev_s, is_height_map);

  let afterDepth  = currentDepthMapValue - currentLayerDepth;
  let beforeDepth = prevDepthMapValue - currentLayerDepth + layerDepth;
  
  let weight = afterDepth / (afterDepth - beforeDepth);
  
  res.uv = mix(currentTexCoords, prevTexCoords, weight);
  // Final perceived height relative to the base plane
  res.height = mix(currentLayerDepth, currentLayerDepth - layerDepth, weight);
  res.hit = true;
  return res;
}

fn calculate_shadow_pom(current_uv: vec2f, current_height: f32, light_dir_ts: vec3f, mat: Material, height_idx: i32) -> PomResult {
  var res: PomResult;
  res.hit = false;
  res.uv = current_uv;
  res.height = current_height;

  // If the light is hitting the back of the polygon or is perfectly horizontal, // it's either in shadow or calculation is undefined.
  if (light_dir_ts.z <= 0.0) { 
    res.hit = true;
    return res; 
  }

  let hm = mat.height_params.y;
  let is_height_map = hm < 0.0;
  let scale = abs(hm);
  let numLayers = mat.height_params.z;
  
  // How much depth we move per step
  let layerDepth = 1.0 / numLayers;
  
  // This is 'p' in your GLSL: the UV offset vector scaled by the height and light angle
  // We use (1.0 - current_height) because we are marching from the displaced point 
  // back up to the "ceiling" (0.0 depth).
  let p = (light_dir_ts.xy / light_dir_ts.z) * scale * (layerDepth);

  var shadow_uv = current_uv;
  var shadow_depth = current_height; // The current depth of the point we found in POM
  
  // We step UP toward the surface (depth 0.0)
  // Note: In POM, depth 0.0 is the top, 1.0 is the bottom.
  for (var i: i32 = 0; i < 32; i++) {
    if (f32(i)/2. >= numLayers || shadow_depth <= 0.0) { break; }
    
    // Move UV toward light and decrease depth (moving toward the surface plane)
    shadow_uv += p;
    shadow_depth -= layerDepth;
    
    let s = sample_texture(height_idx, shadow_uv).r;
    let map_depth = select(s, 1.0 - s, is_height_map);
    
    // If the map says the "wall" is higher (smaller depth) than our ray, we are occluded
    if (map_depth < shadow_depth) {
      res.hit = true;
      res.uv = shadow_uv;
      res.height = map_depth;
      return res;
    }
  }
  
  return res; 
}

fn refraction(I: vec3f, N: vec3f, ior: f32, ior2: f32) -> vec3f {
  var cosi: f32 = clamp(dot(I, N), -1.0, 1.0);
  var n: vec3f = N;
  var etai: f32 = ior2;
  var etat: f32 = ior;

  if (cosi < 0.0) {
    cosi = -cosi;
  } else {
    etai = ior;
    etat = ior2;
    n = -N;
  }

  let eta: f32 = etai / etat;
  let k: f32 = 1.0 - eta * eta * (1.0 - cosi * cosi);
  
  if (k < 0.0) {
    return vec3f(0.0);
  } else {
    return eta * I + (eta * cosi - sqrt(k)) * n;
  }
}

fn fresnel(I: vec3f, N: vec3f, ior: f32, ior2: f32) -> f32 {
  var cosi: f32 = clamp(dot(I, N), -1.0, 1.0);
  var etai: f32 = ior2;
  var etat: f32 = ior;

  if (cosi > 0.0) {
    etai = ior;
    etat = ior2;
  }

  // Compute sint using Snell's law
  let sint: f32 = (etai / etat) * sqrt(max(0.0, 1.0 - cosi * cosi));

  // Total internal reflection
  if (sint >= 1.0) {
    return 1.0;
  } else {
    let cost: f32 = sqrt(max(0.0, 1.0 - sint * sint));
    let abs_cosi: f32 = abs(cosi);
    
    let Rs: f32 = ((etat * abs_cosi) - (etai * cost)) / ((etat * abs_cosi) + (etai * cost));
    let Rp: f32 = ((etai * abs_cosi) - (etat * cost)) / ((etai * abs_cosi) + (etat * cost));
    
    return (Rs * Rs + Rp * Rp) / 2.0;
  }
}

struct SurfaceContext {
  normal: vec3f,
  surface_normal: vec3f,
  albedo: vec3f,
  roughness: f32,
  metallic: f32,
  emittance: vec3f,
  alpha: f32,
};

fn get_surface_context(hit: SurfaceHit, mat: Material, tbn: mat3x3f, uv: vec2f) -> SurfaceContext {
  var ctx: SurfaceContext;
  
  // 1. Resolve Normal (Top Layer/Base)
  ctx.normal = hit.hit_n;
  ctx.surface_normal = hit.hit_n;
  if (mat.normal_idx >= 0) {
    var n_map = sample_texture(mat.normal_idx, uv).xyz * 2.0 - 1.0;
    // Apply normal multiplier from Block 9
    n_map = normalize(n_map * vec3f(mat.height_params.x, mat.height_params.x, 1.0));
    ctx.normal = normalize(tbn * n_map);
  }

  // 2. Resolve Albedo (Base Color)
  ctx.albedo = mat.color;
  ctx.alpha = 1.0;
  if (mat.albedo_idx >= 0) {
    let tex_color = sample_texture(mat.albedo_idx, uv);
    ctx.alpha = tex_color.a;
    ctx.albedo *= pow(tex_color.rgb, vec3f(2.2)); 
  }

  // 3. Resolve Roughness
  // 4. Resolve Metallic
  ctx.metallic = mat.metallic;
  ctx.roughness = mat.roughness;
  // if (mat.roughness_idx == mat.metallic_idx) {
  //   let arm = sample_texture(mat.roughness_idx, uv);
  //   ctx.roughness *= arm.g;
  //   ctx.metallic *= arm.b;
  // } else {
    if (mat.roughness_idx >= 0) {
      ctx.roughness *= sample_texture(mat.roughness_idx, uv).g;
    }
    if (mat.metallic_idx >= 0) {
      ctx.metallic *= sample_texture(mat.metallic_idx, uv).b;
    }
  // }

  // 5. Resolve Emittance (Color * Texture)
  ctx.emittance = mat.emittance;
  if (mat.emissive_idx >= 0) {
    let e_tex = sample_texture(mat.emissive_idx, uv).rgb;
    ctx.emittance *= pow(e_tex, vec3f(2.2));
  }
  
  return ctx;
}

// ---------------------------------------------------------
// SPHERICAL LIGHT SAMPLING (VISIBLE CONE METHOD)
// ---------------------------------------------------------

// Helper: Generates a robust Orthonormal Basis (Frisvad's method)
// Avoids the singularity at z = -1 better than standard cross products.
// fn build_tangent_space(n: vec3f) -> mat3x3f {
//   let sign_z = select(-1.0, 1.0, n.z >= 0.0);
//   let a = -1.0 / (sign_z + n.z);
//   let b = n.x * n.y * a;
  
//   let b1 = vec3f(1.0 + sign_z * n.x * n.x * a, sign_z * b, -sign_z * n.x);
//   let b2 = vec3f(b, sign_z + n.y * n.y * a, -n.y);
  
//   return mat3x3f(b1, b2, n);
// }
// Robust Tangent Space Generation (Duff et al.)
fn build_tangent_space(N: vec3f) -> mat3x3f {
  let a = select(vec3f(0,1,0), vec3f(0,0,1), abs(N.y) > 0.99999);
  let T = normalize(cross(N, a));
  let B = cross(T, N);
  return mat3x3f(T, B, N);
}

struct LightSample {
  dir: vec3f,     // Direction from surface to the light
  color: vec3f,
  dist: f32,      // Distance to the light surface (useful later for shadows)
  pdf: f32,       // Probability Density Function (Solid Angle)
}

fn light_sphere_pdf(light: Light, sphere: TransformedObject, hit_pos: vec3f, dir: vec3f) -> f32 {
  let light_pos = sphere.world_position;

  let d = light_pos - hit_pos;
  let d2 = dot(d, d);
  let r2 = light.scale * light.scale;
  
  // If we are inside the light sphere, it surrounds us completely (4 Pi steradians)
  if (d2 <= r2) {
    return 1.0 / (4.0 * PI);
  }
  
  // Check if the direction actually intersects the sphere
  let tc = dot(d, dir);
  if (tc <= 0.0) { return 0.0; } // Pointing away
  
  let d_perp_sq = d2 - tc * tc;
  if (d_perp_sq > r2) { return 0.0; } // Misses the sphere
  
  // Calculate the subtended cone angle
  let sin_theta_max_sq = r2 / d2;
  let cos_theta_max = sqrt(max(0.0, 1.0 - sin_theta_max_sq));
  
  // Solid angle of the cone
  let solid_angle = TWO_PI * (1.0 - cos_theta_max);
  return 1.0 / max(solid_angle,0.0001);
}

fn sample_light_sphere(light: Light, sphere: TransformedObject, hit_pos: vec3f, xi: vec2f) -> LightSample {
  let light_pos = sphere.world_position;
  let mat = materials[sphere.material_idx];
  
  let d = light_pos - hit_pos;
  let d2 = dot(d, d);
  let r2 = light.scale * light.scale;
  
  var ls: LightSample;
  ls.color = mat.emittance;
  
  if (d2 <= r2) {
    // Inside the light, sample a uniform spherical direction
    let z = 1.0 - 2.0 * xi.x;
    let sin_theta = sqrt(max(0.0, 1.0 - z * z));
    let phi = TWO_PI * xi.y;
    
    ls.dir = vec3f(sin_theta * cos(phi), sin_theta * sin(phi), z);
    ls.dist = 0.0; 
    ls.pdf = 1.0 / (4.0 * PI);
    return ls;
  }
  
  let sin_theta_max_sq = r2 / d2;
  let cos_theta_max = sqrt(max(0.0, 1.0 - sin_theta_max_sq));
  
  // Sample uniformly within the cone subtended by the sphere
  let cos_theta = 1.0 - xi.x * (1.0 - cos_theta_max);
  let sin_theta = sqrt(max(0.0, 1.0 - cos_theta * cos_theta));
  let phi = TWO_PI * xi.y;
  
  let local_dir = vec3f(sin_theta * cos(phi), sin_theta * sin(phi), cos_theta);
  
  // Transform local cone direction to world space
  let w = normalize(d);
  let tbn = build_tangent_space(w);
  ls.dir = normalize(tbn * local_dir);
  
  // Find intersection distance to the sphere surface (for your future shadow rays)
  let tc = dot(d, ls.dir);
  let d_perp_sq = d2 - tc * tc;
  let t_c = sqrt(max(0.0, r2 - d_perp_sq));
  ls.dist = tc - t_c; 
  
  let solid_angle = TWO_PI * (1.0 - cos_theta_max);
  ls.pdf = 1.0 / max(solid_angle,0.0001);
  
  return ls;
}

fn light_box_pdf(light: Light, obj: TransformedObject, hit_pos: vec3f, ray_dir: vec3f, hit: SurfaceHit) -> f32 {
  let v1 = light.matrix[0].xyz;
  let v2 = light.matrix[1].xyz;
  let v3 = light.matrix[2].xyz;
  let cen = light.matrix[3].xyz;

  // Re-calculate the same total area used in sampling
  let d = cen - hit_pos;
  let s1 = select(-1.0, 1.0, dot(d, v1) < 0.0);
  let s2 = select(-1.0, 1.0, dot(d, v2) < 0.0);
  let s3 = select(-1.0, 1.0, dot(d, v3) < 0.0);
  let a1 = length(cross(v2 * 2.0, v3 * 2.0))*max(dot(normalize(-d), normalize(v1 * s1)),0.01);
  let a2 = length(cross(v1 * 2.0, v3 * 2.0))*max(dot(normalize(-d), normalize(v2 * s2)),0.01);
  let a3 = length(cross(v1 * 2.0, v2 * 2.0))*max(dot(normalize(-d), normalize(v3 * s3)),0.01);
  let total_area = a1 + a2 + a3;

  // We need the normal of the specific face we hit to calculate cos_l
  // This can be found via the hit normal from your trace_scene result
  let cos_l = max(dot(-ray_dir, hit.hit_n), 1e-6);
  let dist_sq = hit.t * hit.t;

  return dist_sq / (total_area * cos_l);
}

fn sample_light_box(light: Light, obj: TransformedObject, hit_pos: vec3f, xi: vec2f) -> LightSample {
  let v1 = light.matrix[0].xyz; // Basis X
  let v2 = light.matrix[1].xyz; // Basis Y
  let v3 = light.matrix[2].xyz; // Basis Z
  let cen = light.matrix[3].xyz;

  let d = cen - hit_pos;
  
  // Choose front-facing signs
  let s1 = select(-1.0, 1.0, dot(d, v1) < 0.0);
  let s2 = select(-1.0, 1.0, dot(d, v2) < 0.0);
  let s3 = select(-1.0, 1.0, dot(d, v3) < 0.0);

  // Areas of visible faces (scaled by 2 because box is -1 to 1)
  let a1 = length(cross(v2 * 2.0, v3 * 2.0))*max(dot(normalize(-d), normalize(v1 * s1)),0.01);
  let a2 = length(cross(v1 * 2.0, v3 * 2.0))*max(dot(normalize(-d), normalize(v2 * s2)),0.01);
  let a3 = length(cross(v1 * 2.0, v2 * 2.0))*max(dot(normalize(-d), normalize(v3 * s3)),0.01);
  let total_area = a1 + a2 + a3;

  var p = cen;
  var n = vec3f(0.0);
  let u = xi.x * 2.0 - 1.0;
  let v = xi.y * 2.0 - 1.0;

  // Importance sample the face based on area
  let pick = rand_pcg() * total_area;
  if (pick < a1) {
    p += v1 * s1 + v2 * u + v3 * v;
    n = normalize(v1 * s1);
  } else if (pick < a1 + a2) {
    p += v2 * s2 + v1 * u + v3 * v;
    n = normalize(v2 * s2);
  } else {
    p += v3 * s3 + v1 * u + v2 * v;
    n = normalize(v3 * s3);
  }

  var ls: LightSample;
  let delta = p - hit_pos;
  let dist_sq = dot(delta, delta);
  ls.dist = sqrt(dist_sq);
  ls.dir = delta / ls.dist;
  
  let cos_l = max(dot(-ls.dir, n), 1e-6);
  // Convert Area PDF to Solid Angle PDF
  ls.pdf = (dist_sq) / (total_area * cos_l);
  ls.color = materials[obj.material_idx].emittance;
  
  return ls;
}

fn get_light_pdf(light: Light, obj: TransformedObject, hit_pos: vec3f, dir: vec3f, hit: SurfaceHit) -> f32 {
  if (HAS_SPHERES && obj.object_type == 1) {
    return light_sphere_pdf(light, obj, hit_pos, dir);
  } else if (HAS_CUBES && obj.object_type == 2) {
    return light_box_pdf(light, obj, hit_pos, dir, hit);
  }
  return 0.0;
}

// Samples a random direction towards the spherical light
fn sample_light(light: Light, obj: TransformedObject, hit_pos: vec3f) -> LightSample {
  var samp: LightSample;
  if (HAS_SPHERES && obj.object_type == 1) {
    let xi_light = vec2f(rand_pcg(), rand_pcg());
    samp = sample_light_sphere(light, obj, hit_pos, xi_light);
  } else if (HAS_CUBES && obj.object_type == 2) {
    let xi_light = vec2f(rand_pcg(), rand_pcg());
    samp = sample_light_box(light, obj, hit_pos, xi_light);
  }
  return samp;
}

fn mis_weight(pdf_a: f32, pdf_b: f32) -> f32 {
  if (pdf_a <= 0.0) { return 0.0; }
  // Normalize by the maximum PDF to prevent f32 overflow when squaring
  let max_pdf = max(pdf_a, pdf_b);
  let a = pdf_a / max_pdf;
  let b = pdf_b / max_pdf;
  let a2 = a * a;
  let b2 = b * b;
  let sum = a2 + b2;
  if (sum <= 0.0) { return 0.0; }
  return a2 / sum;
}

struct Medium {
  ior: f32,
  sigma: vec3f,
  emission: vec3f,
}

struct MediumStack {
  media: array<Medium, 4>,
  count: i32,
}

fn peek_medium(stack: ptr<function, MediumStack>) -> Medium {
  if ((*stack).count > 0) {
    return (*stack).media[(*stack).count - 1];
  }
  return Medium(1.0, vec3f(0.0), vec3f(0.0)); // Default: Air
}

fn peek_outer_medium(stack: ptr<function, MediumStack>) -> Medium {
  if ((*stack).count > 1) {
    return (*stack).media[(*stack).count - 2];
  }
  return Medium(1.0, vec3f(0.0), vec3f(0.0)); // Default: Air
}

fn push_medium(stack: ptr<function, MediumStack>, m: Medium) {
  if ((*stack).count < 4) {
    (*stack).media[(*stack).count] = m;
    (*stack).count += 1;
  }
}

fn pop_medium(stack: ptr<function, MediumStack>) {
  if ((*stack).count > 0) {
    (*stack).count -= 1;
  }
}

// 2. UNCAPPED GGX (No more dim lights!)
fn D_GGX(NdotH: f32, alpha2: f32) -> f32 {
  let denom = (NdotH * NdotH * (alpha2 - 1.0) + 1.0);
  // Add a tiny epsilon instead of a max() clamp to preserve the massive specular peak
  return alpha2 / (PI * denom * denom + 1e-10);
}

fn G_Smith_GGX(NdotV: f32, NdotL: f32, alpha2: f32) -> f32 {
  let ggx2 = NdotV * sqrt(max(0.0, alpha2 + NdotL * NdotL * (1.0 - alpha2)));
  let ggx1 = NdotL * sqrt(max(0.0, alpha2 + NdotV * NdotV * (1.0 - alpha2)));
  return (2.0 * NdotL * NdotV) / (ggx1 + ggx2 + 1e-10);
}

fn F_Schlick(cosTheta: f32, F0: vec3f) -> vec3f {
  return F0 + (vec3f(1.0) - F0) * pow(max(0.0, 1.0 - cosTheta), 5.0);
}

fn F_Schlick_Roughness(cosTheta: f32, F0: vec3f, roughness: f32) -> vec3f {
  return F0 + (max(vec3f(1.0 - roughness), F0) - F0) * pow(max(0.0, 1.0 - cosTheta), 5.0);
}

// Explicit Snell's Law / Fresnel Refraction
fn fresnel_dielectric(cosThetaI: f32, etai: f32, etat: f32) -> f32 {
  // We use abs() so normal orientation doesn't break the math
  let cosi = clamp(abs(cosThetaI), 0.0, 1.0);
  let sint = (etai / etat) * sqrt(max(0.0, 1.0 - cosi * cosi));
  
  if (sint >= 1.0) { return 1.0; } // Total Internal Reflection
  
  let cost = sqrt(max(0.0, 1.0 - sint * sint));
  let Rs = ((etat * cosi) - (etai * cost)) / ((etat * cosi) + (etai * cost));
  let Rp = ((etai * cosi) - (etat * cost)) / ((etai * cosi) + (etat * cost));
  
  return (Rs * Rs + Rp * Rp) / 2.0;
}

fn ImportanceSampleGGX(xi: vec2f, N: vec3f, alpha2: f32) -> vec3f {
  let phi = TWO_PI * xi.x;
  let denom = max(1.0 + (alpha2 - 1.0) * xi.y, 1e-7);
  // clamp and max prevent negative domains for sqrt
  let cosTheta = sqrt(clamp((1.0 - xi.y) / denom, 0.0, 1.0));
  let sinTheta = sqrt(max(0.0, 1.0 - cosTheta * cosTheta));
  
  let H_local = vec3f(cos(phi) * sinTheta, sin(phi) * sinTheta, cosTheta);
  
  let up = select(vec3f(0, 1, 0), vec3f(0, 0, 1), abs(N.y) > 0.999);
  let tangent = normalize(cross(up, N));
  let bitangent = cross(N, tangent);
  
  return normalize(tangent * H_local.x + bitangent * H_local.y + N * H_local.z);
}

fn ImportanceSampleCosine(xi: vec2f, N: vec3f) -> vec3f {
  let phi = TWO_PI * xi.x;
  let cosTheta = sqrt(clamp(xi.y, 0.0, 1.0));
  let sinTheta = sqrt(max(0.0, 1.0 - xi.y));
  
  let L_local = vec3f(cos(phi) * sinTheta, sin(phi) * sinTheta, cosTheta);
  
  let up = select(vec3f(0, 1, 0), vec3f(0, 0, 1), abs(N.y) > 0.999);
  let tangent = normalize(cross(up, N));
  let bitangent = cross(N, tangent);
  
  return normalize(tangent * L_local.x + bitangent * L_local.y + N * L_local.z);
}

// =======================================================
// THE MICROFACET EVALUATOR (Reflection & BTDF)
// =======================================================

// 1. Kulla-Conty Energy Preservation (Analytical Fit)
// Accurately predicts the amount of energy lost to microfacet self-shadowing.
fn E_ggx(NdotV: f32, roughness: f32) -> f32 {
  let df = 1.0 - NdotV;
  let df2 = df * df;
  let df3 = df2 * df;
  let r = roughness;
  let a = -0.0761947 - 0.383026 * r;
  let b = 1.04997 + 0.170045 * r;
  let c = 0.0601956 - 0.286214 * r;
  let d = 1.0 - 0.0886567 * r;
  return clamp(a * df3 + b * df2 + c * df + d, 0.05, 1.0);
}
// =======================================================
// THE MICROFACET EVALUATOR (Reflection & BTDF)
// =======================================================

// 1. Physically Accurate Single-Scattering (Reflection)
fn G_Smith_GGX_div_NV(NdotV: f32, NdotL: f32, alpha2: f32) -> f32 {
  let sqrt_v = sqrt(max(0.0, alpha2 + NdotV * NdotV * (1.0 - alpha2)));
  let sqrt_l = sqrt(max(0.0, alpha2 + NdotL * NdotL * (1.0 - alpha2)));
  return (2.0 * NdotL) / (NdotL * sqrt_v + NdotV * sqrt_l + 1e-10);
}

// 2. Physically Accurate Single-Scattering (Transmission)
fn G_Smith_GGX_Uncorrelated_div_NV(NdotV: f32, NdotL: f32, alpha2: f32) -> f32 {
  let lambda_v = NdotV + sqrt(max(0.0, alpha2 + NdotV * NdotV * (1.0 - alpha2)));
  let lambda_l = NdotL + sqrt(max(0.0, alpha2 + NdotL * NdotL * (1.0 - alpha2)));
  return (4.0 * NdotL) / (lambda_v * lambda_l + 1e-7);
}

// 3. G1 Masking Term (Required exclusively for the VNDF Probability density)
fn G1_GGX_div_NV(NdotV: f32, alpha2: f32) -> f32 {
  return 2.0 / (NdotV + sqrt(max(0.0, alpha2 + (1.0 - alpha2) * NdotV * NdotV)) + 1e-7);
}

// Heitz Visible Normal Distribution Function (VNDF) Sampler
fn ImportanceSampleVNDF_GGX(xi: vec2f, V: vec3f, N: vec3f, alpha_ggx: f32) -> vec3f {
  let up = select(vec3f(0.0, 1.0, 0.0), vec3f(0.0, 0.0, 1.0), abs(N.y) > 0.999);
  let T = normalize(cross(up, N));
  let B = cross(N, T);

  let V_local = vec3f(dot(V, T), dot(V, B), dot(V, N));
  let Vh = normalize(vec3f(alpha_ggx * V_local.x, alpha_ggx * V_local.y, max(V_local.z, 0.0)));

  let lensq = Vh.x * Vh.x + Vh.y * Vh.y;
  let T1 = select(vec3f(1.0, 0.0, 0.0), vec3f(-Vh.y, Vh.x, 0.0) / sqrt(max(lensq, 1e-7)), lensq > 0.0);
  let T2 = cross(Vh, T1);

  let r = sqrt(xi.x);
  let phi = 2.0 * PI * xi.y;
  let t1 = r * cos(phi);
  let t2 = r * sin(phi);
  let s = 0.5 * (1.0 + Vh.z);
  let t2_mod = mix(sqrt(max(0.0, 1.0 - t1 * t1)), t2, s);

  let Nh_local = t1 * T1 + t2_mod * T2 + sqrt(max(0.0, 1.0 - t1 * t1 - t2_mod * t2_mod)) * Vh;
  let Ne_local = normalize(vec3f(alpha_ggx * Nh_local.x, alpha_ggx * Nh_local.y, max(0.0, Nh_local.z)));

  return normalize(T * Ne_local.x + B * Ne_local.y + N * Ne_local.z);
}

fn eval_surface(V: vec3f, L: vec3f, mat: Material, ctx: SurfaceContext, stack: ptr<function, MediumStack>) -> vec3f {
  let entering = dot(ctx.normal, V) > 0.0;
  let n_orient = select(-ctx.normal, ctx.normal, entering);
  
  let dotNV = dot(n_orient, V);
  let dotNL = dot(n_orient, L);
  if (dotNV <= 0.0) { return vec3f(0.0); }

  let roughness_val = clamp(ctx.roughness, 0.01, 1.0);
  let alpha = roughness_val * roughness_val;
  let alpha2 = max(alpha * alpha, 1e-6); 

  var etai = 1.0;
  var etat = 1.0;
  if (entering) {
    etai = peek_medium(stack).ior;
    etat = mat.ior;
  } else {
    etai = peek_medium(stack).ior;
    etat = peek_outer_medium(stack).ior;
  }

  // --- 1. REFLECTION LOBES (Same Hemisphere) ---
  if (dotNL > 0.0) {
    let H_vec = V + L;
    let H = select(n_orient, normalize(H_vec), dot(H_vec, H_vec) > 1e-6);
    let dotNH = max(dot(n_orient, H), 0.0);
    let dotVH = max(dot(V, H), 0.0);

    var diff_col = ctx.albedo;
    if (mat.sheen > 0.0) { diff_col += mix(vec3f(1.0), ctx.albedo, mat.sheen_tint) * pow(max(0.0, 1.0 - dotNV), 5.0) * mat.sheen; }
    if (mat.subsurface > 0.0) { diff_col = mix(diff_col, mat.subsurface_tint, mat.subsurface); }
    let diffuse = (diff_col / PI) * (1.0 - ctx.metallic) * (1.0 - mat.transmission);

    let D = D_GGX(dotNH, alpha2);
    let G2_div_NV = G_Smith_GGX_div_NV(dotNV, dotNL, alpha2);
    
    let F_dielectric = fresnel_dielectric(dotVH, etai, etat);

    let lum = dot(ctx.albedo, vec3f(0.2126, 0.7152, 0.0722));
    let tint = select(ctx.albedo / max(lum, 0.0001), vec3f(1.0), lum <= 0.0);
    let F_dielectric_tinted = mix(vec3f(F_dielectric), vec3f(F_dielectric) * tint, mat.specular_tint);
    
    let F0_metal = ctx.albedo;
    let F90_metal = mix(vec3f(1.0), tint, mat.specular_tint);
    let F_metal = F0_metal + (F90_metal - F0_metal) * pow(max(0.0, 1.0 - dotVH), 5.0);
    
    let F_actual = mix(F_dielectric_tinted, F_metal, ctx.metallic);
    
    let F_macro_raw = fresnel_dielectric(dotNV, etai, etat);
    let F0_macro_d = pow((etai - etat) / (etai + etat), 2.0);
    let F_macro_est = mix(F_macro_raw, F0_macro_d, roughness_val);
    let F_macro_metal = ctx.albedo + (vec3f(1.0) - ctx.albedo) * pow(max(0.0, 1.0 - dotNV), 5.0);
    let F_macro_actual = mix(vec3f(F_macro_est), F_macro_metal, ctx.metallic);
    
    let diffuse_cos = diffuse * dotNL * (vec3f(1.0) - F_macro_actual);

    // FIX 1: The Multiplier Energy Fix! 
    // This perfectly boosts rough metals exactly how you suggested, counteracting the GGX loss.
    let ms_factor = 1.0 + alpha * 0.4;
    let specular_cos = (D * F_actual * G2_div_NV) / 4.0 * ms_factor;

    var clearcoat_cos = vec3f(0.0);
    var cc_attenuation = 1.0;
    if (mat.clearcoat > 0.0 && entering) {
      let cc_roughness = clamp(1.0 - mat.clearcoat_gloss, 0.01, 1.0);
      let cc_alpha = cc_roughness * cc_roughness;
      let cc_alpha2 = max(cc_alpha * cc_alpha, 1e-6);
      let cc_D = D_GGX(dotNH, cc_alpha2);
      let cc_G2_div_NV = G_Smith_GGX_div_NV(dotNV, dotNL, cc_alpha2);
      let cc_F = fresnel_dielectric(dotVH, 1.0, mat.clearcoat_ior);
      
      clearcoat_cos = (mat.clearcoat * cc_D * cc_G2_div_NV * vec3f(cc_F)) / 4.0;
      
      let cc_F_macro = fresnel_dielectric(dotNV, 1.0, mat.clearcoat_ior);
      cc_attenuation = 1.0 - (mat.clearcoat * cc_F_macro); 
    }

    // FIX 2: Multiply by ctx.alpha! If alpha is 0, NEE evaluates it to 0 light!
    return ((diffuse_cos + specular_cos) * cc_attenuation + clearcoat_cos) * ctx.alpha;
  } 
  
  // --- 2. TRANSMISSION BTDF (Opposite Hemisphere) ---
  else if (dotNL < 0.0 && mat.transmission > 0.0) {
    let H_vec = -(etai * V + etat * L);
    var H = normalize(H_vec);
    if (dot(H, n_orient) < 0.0) { H = -H; } 

    let dotNH = max(dot(n_orient, H), 0.0);
    let dotVH = dot(V, H);
    let dotLH = dot(L, H);

    if (dotVH * dotLH >= 0.0) { return vec3f(0.0); } 

    let D = D_GGX(dotNH, alpha2);
    let G2_unc_div_NV = G_Smith_GGX_Uncorrelated_div_NV(dotNV, abs(dotNL), alpha2);
    let F_dielectric = fresnel_dielectric(dotVH, etai, etat);

    let denom = etai * dotVH + etat * dotLH;
    let denom2 = max(denom * denom, 1e-7);
    
    // FIX 3: Uniform multiplier energy fix for Frosted Glass!
    let ms_factor = 1.0 + alpha * 0.25;
    let btdf_cos = (abs(dotVH) * abs(dotLH) * etat * etat * (1.0 - F_dielectric) * D * G2_unc_div_NV) / denom2 * ms_factor;

    var cc_attenuation = 1.0;
    if (mat.clearcoat > 0.0 && entering) {
      let cc_F_macro = fresnel_dielectric(dotNV, 1.0, mat.clearcoat_ior);
      cc_attenuation = 1.0 - (mat.clearcoat * cc_F_macro);
    }

    let trans_color = vec3f(mat.transmission * (1.0 - ctx.metallic));
    return trans_color * btdf_cos * cc_attenuation * ctx.alpha;
  }

  return vec3f(0.0);
}

// =======================================================
// THE MICROFACET PDF (VNDF Integration)
// =======================================================
fn pdf_surface(V: vec3f, L: vec3f, mat: Material, ctx: SurfaceContext, stack: ptr<function, MediumStack>) -> f32 {
  let entering = dot(ctx.normal, V) > 0.0;
  let n_orient = select(-ctx.normal, ctx.normal, entering);
  
  let dotNV = dot(n_orient, V);
  let dotNL = dot(n_orient, L);
  if (dotNV <= 0.0) { return 1e-7; }

  let roughness_val = clamp(ctx.roughness, 0.01, 1.0);
  let alpha = roughness_val * roughness_val;
  let alpha2 = max(alpha * alpha, 1e-6);

  var etai = 1.0;
  var etat = 1.0;
  if (entering) {
    etai = peek_medium(stack).ior;
    etat = mat.ior;
  } else {
    etai = peek_medium(stack).ior;
    etat = peek_outer_medium(stack).ior;
  }

  let F_cc = fresnel_dielectric(dotNV, 1.0, mat.clearcoat_ior);
  let p_cc = select(0.0, mat.clearcoat * F_cc, entering);
  
  let F_est_raw = fresnel_dielectric(dotNV, etai, etat);
  let F0_d = pow((etai - etat) / (etai + etat), 2.0);
  let F_est = mix(F_est_raw, F0_d, roughness_val);
  
  let F_metal = ctx.albedo + (vec3f(1.0) - ctx.albedo) * pow(max(0.0, 1.0 - dotNV), 5.0);
  let F_actual = mix(vec3f(F_est), F_metal, ctx.metallic);
  
  let f_avg = clamp((F_actual.r + F_actual.g + F_actual.b) / 3.0, 0.0, 1.0);
  let p_spec = (1.0 - p_cc) * f_avg;
  let p_trans = (1.0 - p_cc) * (1.0 - f_avg) * mat.transmission * (1.0 - ctx.metallic);
  let p_diff = (1.0 - p_cc) * (1.0 - f_avg) * (1.0 - mat.transmission) * (1.0 - ctx.metallic);

  var pdf: f32 = 0.0;

  if (dotNL > 0.0) {
    let H_vec = V + L;
    let H = select(n_orient, normalize(H_vec), dot(H_vec, H_vec) > 1e-6);
    let dotNH = max(dot(n_orient, H), 0.0);
    let dotVH = max(dot(V, H), 0.0);

    if (p_diff > 0.0) { pdf += p_diff * (dotNL / PI); }
    
    if (p_spec > 0.0) {
      let D = D_GGX(dotNH, alpha2);
      let G1_div_NV = G1_GGX_div_NV(dotNV, alpha2);
      var spec_weight = p_spec;
      
      if (p_trans > 0.0) {
        let cosi = clamp(dotVH, 0.0, 1.0);
        let sint = (etai / etat) * sqrt(max(0.0, 1.0 - cosi * cosi));
        if (sint >= 1.0) { spec_weight += p_trans; }
      }
      
      let pdf_H = G1_div_NV * D * max(0.0, dotVH);
      pdf += spec_weight * pdf_H / max(4.0 * dotVH, 1e-7);
    }
    
    if (p_cc > 0.0) {
      let cc_roughness = clamp(1.0 - mat.clearcoat_gloss, 0.01, 1.0);
      let cc_alpha = cc_roughness * cc_roughness;
      let cc_alpha2 = max(cc_alpha * cc_alpha, 1e-6);
      let cc_D = D_GGX(dotNH, cc_alpha2);
      let cc_G1_div_NV = G1_GGX_div_NV(dotNV, cc_alpha2);
      
      let pdf_H_cc = cc_G1_div_NV * cc_D * max(0.0, dotVH);
      pdf += p_cc * pdf_H_cc / max(4.0 * dotVH, 1e-7);
    }
  } 
  else if (dotNL < 0.0 && p_trans > 0.0) {
    let H_vec = -(etai * V + etat * L);
    var H = normalize(H_vec);
    if (dot(H, n_orient) < 0.0) { H = -H; }

    let dotNH = max(dot(n_orient, H), 0.0);
    let dotVH = dot(V, H);
    let dotLH = dot(L, H);

    if (dotVH * dotLH < 0.0) {
      let D = D_GGX(dotNH, alpha2);
      let G1_div_NV = G1_GGX_div_NV(dotNV, alpha2);
      let pdf_H = G1_div_NV * D * max(0.0, dotVH);

      let denom = etai * dotVH + etat * dotLH;
      let dwh_dwi = (etat * etat * abs(dotLH)) / max(denom * denom, 1e-7);
      pdf += p_trans * pdf_H * dwh_dwi;
    }
  }

  // FIX 4: Match the BSDF attenuation multiplier!
  return max(pdf, 1e-7) * ctx.alpha;
}

// =======================================================
// THE UNIFIED SAMPLER (VNDF Integration)
// =======================================================
fn sample_surface(ray: ptr<function, Ray>, throughput: ptr<function, vec3f>, radiance: ptr<function, vec3f>, hit: SurfaceHit, mat: Material, ctx: SurfaceContext, hit_pos: vec3f, stack: ptr<function, MediumStack>, last_surface_pdf: ptr<function, f32>) -> bool {
  let V = -(*ray).direction;
  let entering = dot(ctx.normal, V) > 0.0;
  
  let n_orient = select(-ctx.normal, ctx.normal, entering);
  let sn_orient = select(-ctx.surface_normal, ctx.surface_normal, entering);
  let dotSNV = max(dot(sn_orient, V), 1e-6);
  
  let roughness_val = clamp(ctx.roughness, 0.01, 1.0);
  let alpha = roughness_val * roughness_val;

  let cc_roughness = clamp(1.0 - mat.clearcoat_gloss, 0.01, 1.0);
  let cc_alpha = cc_roughness * cc_roughness;

  var etai = 1.0;
  var etat = 1.0;
  if (entering) {
    etai = peek_medium(stack).ior;
    etat = mat.ior;
  } else {
    etai = peek_medium(stack).ior;
    etat = peek_outer_medium(stack).ior;
  }

  let cc_F_est = fresnel_dielectric(dotSNV, 1.0, mat.clearcoat_ior);
  let w_cc = select(0.0, mat.clearcoat * cc_F_est, entering);
  
  let F_est_raw = fresnel_dielectric(dotSNV, etai, etat);
  let F0_d = pow((etai - etat) / (etai + etat), 2.0);
  let F_est = mix(F_est_raw, F0_d, roughness_val);
  
  let F_metal = ctx.albedo + (vec3f(1.0) - ctx.albedo) * pow(max(0.0, 1.0 - dotSNV), 5.0);
  let F_actual = mix(vec3f(F_est), F_metal, ctx.metallic);
  
  let f_avg = clamp((F_actual.r + F_actual.g + F_actual.b) / 3.0, 0.0, 1.0);
  let p_cc = w_cc;
  let p_spec = (1.0 - p_cc) * f_avg;
  let p_trans = (1.0 - p_cc) * (1.0 - f_avg) * mat.transmission * (1.0 - ctx.metallic);
  let p_diff = (1.0 - p_cc) * (1.0 - f_avg) * (1.0 - mat.transmission) * (1.0 - ctx.metallic);
  let total_p = p_cc + p_spec + p_trans + p_diff;

  if (rand_pcg() > ctx.alpha) {
    (*ray).origin = hit_pos - n_orient * 0.005;
    return true; 
  }
  
  let rng = rand_pcg();
  let xi = vec2f(rand_pcg(), rand_pcg());
  var L = vec3f(0.0);
  var is_transmission = false;

  if (rng < p_cc) {
    let H = ImportanceSampleVNDF_GGX(xi, V, sn_orient, cc_alpha);
    L = reflect(-V, H);
  } else if (rng < p_cc + p_spec) {
    var N_spec = n_orient;
    if (mat.anisotropic > 0.0) {
      let up = select(vec3f(0,1,0), vec3f(0,0,1), abs(n_orient.y) > 0.99999);
      var T = normalize(cross(up, n_orient));
      var B = cross(n_orient, T);
      let angle = mat.aniso_rotation * TWO_PI;
      T = T * cos(angle) + B * sin(angle);
      N_spec = normalize(mix(n_orient, cross(cross(V, T), T), mat.anisotropic));
    }
    let H = ImportanceSampleVNDF_GGX(xi, V, N_spec, alpha);
    L = reflect(-V, H);
  } else if (rng < p_cc + p_spec + p_trans) {
    
    if (abs(etai - etat) < 1e-4) {
      (*ray).direction = -V;
      (*ray).origin = hit_pos - n_orient * 0.001; 
      (*throughput) *= vec3f(mat.transmission * (1.0 - ctx.metallic));
      (*last_surface_pdf) = p_trans;
      
      if (entering) {
        let sigma = -log(max(ctx.albedo.rgb, vec3f(0.0001))) * mat.concentration;
        push_medium(stack, Medium(mat.ior, sigma, mat.emittance.rgb));
      } else { pop_medium(stack); }
      return true; 
    }
    
    let H = ImportanceSampleVNDF_GGX(xi, V, n_orient, alpha);
    let eta_ratio = etai / etat;
    L = refract(-V, H, eta_ratio);
    
    if (length(L) < 0.1) { L = reflect(-V, H); } // TIR guaranteed fallback
    else { is_transmission = true; }
  } else if (rng < total_p) {
    L = ImportanceSampleCosine(xi, n_orient);
  } else { return false; }

  let dotNL = dot(n_orient, L);
  
  if (is_transmission) {
    if (dotNL >= 0.0) { return false; } 
    (*ray).origin = hit_pos - n_orient * 0.001; 
  } else {
    if (dotNL <= 0.0) { return false; } 
    (*ray).origin = hit_pos + n_orient * 0.001; 
  }

  (*ray).direction = L;
  
  let bsdf_val = eval_surface(V, L, mat, ctx, stack);
  let pdf_val = pdf_surface(V, L, mat, ctx, stack);

  // Because both bsdf_val and pdf_val are multiplied by ctx.alpha, 
  // they cancel out here to precisely 1.0, preserving the energy perfectly
  // for the rays that survive the initial Russian Roulette check!
  if (pdf_val > 0.0) { (*throughput) *= bsdf_val / pdf_val; } 
  else { return false; }
  
  (*last_surface_pdf) = pdf_val;

  if (is_transmission) {
    if (entering) {
      let albedo_rgb = vec3f(ctx.albedo.r, ctx.albedo.g, ctx.albedo.b);
      let sigma = -log(max(albedo_rgb, vec3f(0.0001))) * mat.concentration;
      push_medium(stack, Medium(mat.ior, sigma, mat.emittance.rgb));
    } else { pop_medium(stack); }
  }

  return true; 
}

const FIREFLY_CLAMP: f32 = 20.0; 

fn clamp_firefly(rad: vec3f, bounce: i32) -> vec3f {
  // NEVER clamp the primary ray (bounce == 0), otherwise 
  // looking directly at a light source will look gray/dull!
  if (bounce == 0) { return rad; }
  
  let lum = dot(rad, vec3f(0.2126, 0.7152, 0.0722));
  if (lum > FIREFLY_CLAMP) {
    return rad * (FIREFLY_CLAMP / lum);
  }
  return rad;
}

// fn evaluate_nee(light_sample: LightSample, hit_pos: vec3f, n_orient: vec3f, V: vec3f, mat: Material, ctx: SurfaceContext, tbn: mat3x3f, currentheight: f32, final_uv: vec2f, stack: ptr<function, MediumStack>, ignore_obj_idx: i32) -> vec3f {
//   if (light_sample.pdf <= 0.0) { return vec3f(0.0); }
  
//   let dotNL = dot(n_orient, light_sample.dir);
//   if (dotNL <= 0.0 && mat.transmission <= 0.0) { return vec3f(0.0); } 

//   // Offset using n_orient since it already faces the incoming ray
//   let ray_offset = select(n_orient * 0.001, -n_orient * 0.001, dotNL < 0.0);
//   let shadow_ray = Ray(hit_pos + ray_offset, light_sample.dir);
//   var in_shadow = false;
//   var sample_color = light_sample.color;

//   if (HAS_HEIGHTMAPS && mat.height_idx >= 0) {
//     let light_ts = normalize(transpose(tbn) * light_sample.dir);
//     let shadow_res = calculate_shadow_pom(final_uv, currentheight, light_ts, mat, mat.height_idx);
//     if (shadow_res.hit) { in_shadow = true; }
//   }
  
//   if (!in_shadow) {
//     let shadow_hit = trace_scene_shadow(shadow_ray, ignore_obj_idx, light_sample.dist);
//     sample_color *= shadow_hit;
//     if (max_component(shadow_hit) < 0.001) { in_shadow = true; }
//   }

//   if (!in_shadow) {
//     let bsdf_pdf = pdf_surface(V, light_sample.dir, mat, ctx, stack);  
//     let weight = mis_weight(light_sample.pdf, bsdf_pdf);
//     let bsdf_val = eval_surface(V, light_sample.dir, mat, ctx, stack); 
    
//     return (sample_color * bsdf_val * weight) / max(light_sample.pdf, 1e-6);
//   }
  
//   return vec3f(0.0);
// }

fn evaluate_nee(light_sample: LightSample, hit_pos: vec3f, n_orient: vec3f, V: vec3f, mat: Material, ctx: SurfaceContext, tbn: mat3x3f, currentheight: f32, final_uv: vec2f, stack: ptr<function, MediumStack>, ignore_obj_idx: i32, bounce: i32) -> vec3f {
  if (light_sample.pdf <= 0.0) { return vec3f(0.0); }
  
  let dotNL = dot(n_orient, light_sample.dir);
  if (dotNL <= 0.0 && mat.transmission <= 0.0) { return vec3f(0.0); } 

  let bsdf_pdf = pdf_surface(V, light_sample.dir, mat, ctx, stack);  
  var weight = mis_weight(light_sample.pdf, bsdf_pdf);
  let bsdf_val = eval_surface(V, light_sample.dir, mat, ctx, stack); 
  var sample_color = light_sample.color;
  
  // luma(throughput*contrib)*1/(1+(p_brdf/(p_light*p_survival))^2)=p_survival
  // 
  // if (bounce > 0) {
  //   let survival_prob = clamp(weight, 0.05, 1);
  //   if (rand_pcg() > survival_prob) { return vec3f(0.0); }
  //   weight /= survival_prob;
  // }

  var c_weight = weight * bsdf_val / max(light_sample.pdf, 1e-6);
  
  if (max_component(sample_color * c_weight) < 1e-5) { return vec3f(0.0); }

  // Offset using n_orient since it already faces the incoming ray
  let ray_offset = select(n_orient * 0.001, -n_orient * 0.001, dotNL < 0.0);
  let shadow_ray = Ray(hit_pos + ray_offset, light_sample.dir);
  var in_shadow = false;

  if (HAS_HEIGHTMAPS && mat.height_idx >= 0) {
    let light_ts = normalize(transpose(tbn) * light_sample.dir);
    let shadow_res = calculate_shadow_pom(final_uv, currentheight, light_ts, mat, mat.height_idx);
    if (shadow_res.hit) { in_shadow = true; }
  }
  
  if (!in_shadow) {
    let shadow_hit = trace_scene_shadow(shadow_ray, ignore_obj_idx, light_sample.dist);
    sample_color *= shadow_hit;
    if (max_component(shadow_hit) < 0.001) { in_shadow = true; }
  }

  if (!in_shadow) {
    return sample_color * c_weight;
  }
  
  return vec3f(0.0);
}

@compute @workgroup_size(16, 16)
fn main(@builtin(global_invocation_id) sid: vec3u) {
  let id = params.section + sid.xy;
  if (id.x >= params.width || id.y >= params.height) { return; }
  let idx = id.y * params.width + id.x;
  
  //rng_state = idx + params.sample_number * 912373u;
  rng_state = (idx * 1973u + params.sample_number * 9277u + params.seed * 26699u) | 1u;
  //rng_state = (idx ^ (params.sample_number * 912373u) ^ (params.seed * 26699u)) | 1u;
  rand_pcg();

  let screen_uv = (vec2f(id.xy) + vec2f(rand_pcg(), rand_pcg())) / vec2f(f32(params.width), f32(params.height));
  // let screen_uv = (vec2f(id.xy) + vec2f(0.5)) / vec2f(f32(params.width), f32(params.height)); // no anti-aliasing
  let ray_dir = normalize(mix(mix(params.ray00, params.ray10, screen_uv.x), mix(params.ray01, params.ray11, screen_uv.x), 1.-screen_uv.y));
  var ray = Ray(params.eye, ray_dir);

  // var hit = trace_scene(ray); 
  // if (hit.m_idx == -1) {
  //   textureStore(output_tex, id.xy, vec4f(vec3f(0.0), 1.0));
  //   return;
  // }
  // var mat = materials[hit.m_idx];
  // let tbn = mat3x3f(hit.tangent, hit.bitangent, hit.hit_n);
  // var final_uv = hit.hit_uv * mat.uv_scale;
  // var ctx = get_surface_context(hit, mat, tbn, final_uv);
  // textureStore(output_tex, id.xy, vec4f(vec3f(hit.t/50.0), 1.0));
  // textureStore(output_tex, id.xy, vec4f(hit.hit_n * 0.5 + vec3f(0.5), 1.0));
  // textureStore(output_tex, id.xy, vec4f(ray.origin + hit.t * ray.direction, 1.0));
  // textureStore(output_tex, id.xy, vec4f(ctx.albedo, 1.0));
  // hit.hit_uv = fract(hit.hit_uv); textureStore(output_tex, id.xy, vec4f(hit.hit_uv.x,hit.hit_uv.y,1. - hit.hit_uv.x * hit.hit_uv.y, 1.0));
  // textureStore(output_tex, id.xy, vec4f(vec3f(pow(0.97,f32(hit.count))),1.0));
  // return;

  //var shadow = trace_scene_shadow(ray, -1, 10);
  //textureStore(output_tex, id.xy, vec4f(shadow, 1.0));
  //return;
  
  var throughput = vec3f(1.0);
  var radiance = vec3f(0.0);
  var last_surface_pdf = 1.0; 
  var last_weight_sum = 0.0;
  
  // Initialize the empty stack (Defaults to Air implicitly)
  var stack: MediumStack;
  stack.count = 0;

  for (var bounce = 0; bounce < BOUNCE_LIMIT; bounce++) {
    var hit = trace_scene(ray);
    var obj: TransformedObject;
    if (hit.o_idx >= 0) { obj = objects[hit.o_idx]; }
    //throughput*=pow(0.9,f32(hit.count));

    // --- 1. GLOBAL VOLUME ATTENUATION (Beer's Law) ---
    // This perfectly tracks continuous distance through the current medium.
    let current_med = peek_medium(&stack);
    if (current_med.ior > 1.0 || length(current_med.sigma) > 0.0) { 
      let dist = select(hit.t, 1000.0, hit.m_idx == -1); 
      let attenuation = exp(-current_med.sigma * dist);
      
      // FIX: Physically correct volumetric emission integral!
      // Formula: (emission * (1 - exp(-sigma * d))) / sigma
      let sigma = current_med.sigma;
      let emit_x = select(current_med.emission.x * dist, current_med.emission.x * (1.0 - attenuation.x) / sigma.x, sigma.x > 1e-4);
      let emit_y = select(current_med.emission.y * dist, current_med.emission.y * (1.0 - attenuation.y) / sigma.y, sigma.y > 1e-4);
      let emit_z = select(current_med.emission.z * dist, current_med.emission.z * (1.0 - attenuation.z) / sigma.z, sigma.z > 1e-4);
      
      let incoming = vec3f(emit_x, emit_y, emit_z);
      radiance += throughput * clamp_firefly(incoming, bounce);
      throughput *= attenuation;
    }
    
    if (hit.m_idx == -1) {
      if (HAS_SKYBOX) {
        var sky_color = sample_sky(ray.direction);
        var weight = 1.0;
        if (bounce > 0 && MIS_SKYBOX) {
          let sky_pdf = get_sky_pdf(ray.direction);
          weight = mis_weight(last_surface_pdf, sky_pdf);
        }
        let incoming = sky_color * weight;
        radiance += throughput * clamp_firefly(incoming, bounce);
      } else { 
        radiance += throughput * clamp_firefly(vec3f(0.02, 0.03, 0.05), bounce);
      }
      break;
    }

    let mat = materials[hit.m_idx];
    var final_uv = hit.hit_uv * mat.uv_scale;
    let tbn = mat3x3f(hit.tangent, hit.bitangent, hit.hit_n);
    var currentheight = 0.;

    let height_idx = mat.height_idx;
    if (HAS_HEIGHTMAPS && height_idx >= 0) {
      let view_ts = normalize(transpose(tbn) * (-ray.direction)); 
      if (view_ts.z > 0.0) {
        let pom = calculate_pom(final_uv, view_ts, 0., mat, height_idx);
        final_uv = pom.uv;
        currentheight = pom.height;
      }
    }

    let ctx = get_surface_context(hit, mat, tbn, final_uv);

    // --- IMPLICIT LIGHT HIT (BSDF Bounce) ---
    if (length(ctx.emittance) > 0.0) {
      var weight = 1.0;
      if (HAS_LIGHTS && bounce > 0 && hit.o_idx >= 0 && obj.light_idx >= 0) {
        let light = lights[obj.light_idx];
        let raw_light_pdf = get_light_pdf(light, obj, ray.origin, ray.direction, hit);
        let to_light = obj.world_position - ray.origin;
        let d2 = max(dot(to_light, to_light), 0.001);
        let light_importance = light.power / d2;
        let selection_pdf = select(0.0, light_importance / last_weight_sum, last_weight_sum > 0.0);
        let total_light_pdf = raw_light_pdf * selection_pdf;
        weight = mis_weight(last_surface_pdf, total_light_pdf);
      }
      let incoming = ctx.emittance.rgb * weight;
      radiance += throughput * clamp_firefly(incoming, bounce);
      //if (HAS_LIGHTS && hit.o_idx > 0 && obj.light_idx >= 0) { break; }
      //else 
      if (length(ctx.emittance) > 1.0) { break; }
    }

    let hit_pos = ray.origin + ray.direction * hit.t;
    let V = -ray.direction;
    let n_orient = select(-ctx.normal, ctx.normal, dot(ctx.normal, V) > 0.0);

    // --- EXPLICIT LIGHT SAMPLING (NEE) ---
    if (HAS_LIGHTS) {
      var selected_light_idx: i32 = -1;
      var weight_sum = 0.0;
      var selected_weight = 0.0;
      
      // 1. Evaluate all lights in a single pass (Reservoir Sampling)
      let num_lights = arrayLength(&lights);
      for (var i = 0u; i < num_lights; i++) {
        let light = lights[i];
        if (light.obj_idx < 0) { continue; }
        let l_obj = objects[light.obj_idx];
        
        // Calculate importance heuristic (Power / Distance^2)
        let to_light = l_obj.world_position - hit_pos;
        let d2 = max(dot(to_light, to_light), 0.001);
        let w = light.power / d2;
        
        weight_sum += w;
        
        // Mathematically guaranteed selection based on relative weight
        if (rand_pcg() < (w / weight_sum)) {
          selected_light_idx = i32(i);
          selected_weight = w;
        }
      }
      
      // 2. Evaluate the single chosen light
      if (selected_light_idx >= 0 && weight_sum > 0.0) {
        let light = lights[u32(selected_light_idx)];
        let l_obj = objects[light.obj_idx];

        var light_sample = sample_light(light, l_obj, hit_pos);
        if (light_sample.pdf > 0.0) {
          
          // FIX: Multiply the raw directional PDF by the chance we picked this light
          let selection_pdf = selected_weight / weight_sum;
          light_sample.pdf *= selection_pdf;
          
          let incoming = evaluate_nee(light_sample, hit_pos, n_orient, V, mat, ctx, tbn, currentheight, final_uv, &stack, light.obj_idx, bounce);
          radiance += throughput * clamp_firefly(incoming, bounce);
        }
      }

      last_weight_sum = weight_sum; 
    }

    // --- DIRECT SKY SAMPLING (NEE) ---
    if (HAS_SKYBOX && MIS_SKYBOX) {
      var env_sample = sample_env_cdf(vec2f(rand_pcg(), rand_pcg()));
      let incoming = evaluate_nee(env_sample, hit_pos, n_orient, V, mat, ctx, tbn, currentheight, final_uv, &stack, -1, bounce);
      radiance += throughput * clamp_firefly(incoming, bounce);
    }
    
    // NOTE: &beers_dist has been removed from these calls!
    if (!sample_surface(&ray, &throughput, &radiance, hit, mat, ctx, hit_pos, &stack, &last_surface_pdf)) { break; }

    // --- HEIGHTMAP / POM SHADOW LOGIC ---
    if (HAS_HEIGHTMAPS && mat.height_idx >= 0) {
      let light_ts = normalize(transpose(tbn) * (ray.direction));
      let shadow_res = calculate_shadow_pom(final_uv, currentheight, light_ts, mat, mat.height_idx);
      if (shadow_res.hit) {
        final_uv = shadow_res.uv;
        let ctx_pom = get_surface_context(hit, mat, tbn, final_uv);
        
        let incoming = ctx_pom.emittance.rgb;
        radiance += throughput * clamp_firefly(incoming, bounce);
        
        if (length(ctx_pom.emittance) > 1.0) { break; }
        if (!sample_surface(&ray, &throughput, &radiance, hit, mat, ctx_pom, hit_pos, &stack, &last_surface_pdf)) { break; }
      }
    }

    // Russian Roulette
    if (bounce < 2) { continue; } 
    let p = max_component(throughput);
    let survival_prob = clamp(p, 0.05, 0.95);
    if (rand_pcg() > survival_prob) { break; }
    throughput /= survival_prob;
  }
  
  let weight = 1.0 / f32(params.sample_number + 1u);
  let old_c = accum_buffer[idx].rgb;
  var final_c = mix(old_c, radiance, weight);
  accum_buffer[idx] = vec4f(final_c, 1.0);
  
  final_c *= vec3f(params.exposure);
  final_c = final_c / (final_c + vec3(0.3));
  final_c = pow(final_c, vec3f(0.4545));
  
  textureStore(output_tex, id.xy, vec4f(final_c, 1.0));
}


// Get gbuffer data

struct GBufferData {
  normal: vec3f,
  roughness: f32,
  albedo: vec3f,
  metallic: f32,
  motion: vec2f,
  transmission: f32,
  dist: f32,
};

// The new buffer for the Denoiser
@group(0) @binding(17) var<storage, read_write> g_buffer: array<GBufferData>;

@compute @workgroup_size(16, 16)
fn gbuf_main(@builtin(global_invocation_id) sid: vec3u) {
  let id = params.section + sid.xy;
  if (id.x >= params.width || id.y >= params.height) { return; }
  let idx = id.y * params.width + id.x;
  
  //rng_state = idx + params.sample_number * 912373u;
  rng_state = (idx * 1973u + params.sample_number * 9277u + params.seed * 26699u) | 1u;
  //rng_state = (idx ^ (params.sample_number * 912373u) ^ (params.seed * 26699u)) | 1u;
  rand_pcg();

  _ = params;
  _ = accum_buffer[0];
  _ = output_tex;

  let screen_uv = (vec2f(id.xy) + vec2f(0.5)) / vec2f(f32(params.width), f32(params.height)); // no aliasing
  let ray_dir = normalize(mix(mix(params.ray00, params.ray10, screen_uv.x), mix(params.ray01, params.ray11, screen_uv.x), 1.-screen_uv.y));
  var ray = Ray(params.eye, ray_dir);

  var hit: SurfaceHit;
  var first_hit: SurfaceHit;
  var ctx: SurfaceContext;
  var first_ctx: SurfaceContext;
  var mat: Material;
  var dist = 0.0;
  var first = true;

  var tint = vec3f(1.);
  for (var bounce = 0; bounce < BOUNCE_LIMIT; bounce++) {
    hit = trace_scene(ray); 
    if (hit.m_idx == -1) {
      ctx.normal = vec3f(0.0);
      ctx.emittance = sample_sky(ray.direction);
      ctx.albedo = vec3f(0.0);
      first_ctx = ctx;
      break;
    }
    mat = materials[hit.m_idx];
    let tbn = mat3x3f(hit.tangent, hit.bitangent, hit.hit_n);
    var final_uv = hit.hit_uv * mat.uv_scale;
    ctx = get_surface_context(hit, mat, tbn, final_uv);
    ctx.normal = select(-ctx.normal, ctx.normal, dot(ctx.normal, -ray.direction) > 0.0);
    dist += hit.t;
    if (ctx.alpha < 1) {
      tint *= mix(vec3f(1.0), ctx.albedo, ctx.alpha);
      ray.origin = ray.origin + ray.direction * hit.t - ctx.normal * 0.001;
      continue;
    }
    if (first) {
      first_ctx = ctx;
      first_hit = hit;
      first = false;
    }
    if (mat.metallic >= 0.99 && mat.roughness <= 0.01) {
      tint *= ctx.albedo;
      ray.origin = ray.origin + ray.direction * hit.t + ctx.normal * 0.001;
      ray.direction = reflect(ray.direction, ctx.normal);
      continue;
    }
    break;
  }

  var color = (ctx.albedo + ctx.emittance) * tint;
  
  g_buffer[idx].normal = ctx.normal;
  g_buffer[idx].albedo = color;
  g_buffer[idx].dist = dist;
  g_buffer[idx].transmission = mat.transmission;
  g_buffer[idx].roughness = ctx.roughness;
  g_buffer[idx].metallic = ctx.metallic;

  if (id.x < params.width * 1 / 4) {
    dist = dist / (dist + 3.0);
    textureStore(output_tex, id.xy, vec4f(vec3f(dist), 1.0));
    //textureStore(output_tex, id.xy, vec4f(vec3f(hit.t/50.0), 1.0));
    //textureStore(output_tex, id.xy, vec4f(ray.origin + hit.t * ray.direction, 1.0));
  } else if (id.x < params.width * 2 / 4) {
    textureStore(output_tex, id.xy, vec4f(ctx.normal * 0.5 + vec3f(0.5), 1.0));
  } else if (id.x < params.width * 3 / 4) {
    color *= vec3f(params.exposure);
    color = color / (color + vec3(0.3));
    color = pow(color, vec3f(0.4545));
    textureStore(output_tex, id.xy, vec4f(color, 1.0));
  } else {
    textureStore(output_tex, id.xy, vec4f(vec3f(mat.transmission,ctx.roughness,ctx.metallic), 1.0));
  }
  // hit.hit_uv = fract(hit.hit_uv); textureStore(output_tex, id.xy, vec4f(hit.hit_uv.x,hit.hit_uv.y,1. - hit.hit_uv.x * hit.hit_uv.y, 1.0));
  // textureStore(output_tex, id.xy, vec4f(vec3f(pow(0.97,f32(hit.count))),1.0));
  // return;

  //var shadow = trace_scene_shadow(ray, -1, 10);
  //textureStore(output_tex, id.xy, vec4f(shadow, 1.0));
  //return;
}

