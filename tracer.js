//import { vec3, mat4, quat } from 'https://cdn.jsdelivr.net/npm/gl-matrix@3.4.3/+esm';
const { vec3, vec4, mat4, quat } = glMatrix;

// --- SCENE DEFINITION ---
class Texture {
  constructor(url,name) {
    this.id = 'texture_' + Math.random().toString(36).substr(2, 9);
    this.name = name || "New Texture";

    this.url = url;
    this.image = new Image();
    this.image.crossOrigin = "anonymous";
    this.texIndex = -1;
    this.loaded = new Promise(resolve => {
      this.image.onload = () => resolve(this);
      this.image.onerror = () => { console.error("Failed to load:", url); resolve(this); };
      this.image.src = url;
    });
  }
}

class HDRTexture {
  constructor(url, name, exposure = 1) {
    this.id = 'hdrtexture_' + Math.random().toString(36).substr(2, 9);
    this.url = url;
    this.name = name || "New HDR Texture";
    this.width = 1;
    this.height = 1;
    this.exposure = exposure;
    this.threshold = 65536-16-1; // magic constant (i binary searched to get it)
    this.thumbnailURL = {};
    this.enableNEE = true;
    if (!url) url = [0.02, 0.03, 0.05, 1.0]; // Float16Array
    // Check if url is a vec3/vec4 array (solid color)
    if (Array.isArray(url) || (url instanceof Float32Array && url.length <= 4)) {
      this.width = 1;
      this.height = 1;
      this.data = new Float16Array([url[0], url[1], url[2], 1.0]);
      this.loaded = Promise.resolve();
      this.plainColor = true;
    } else if (typeof url === 'string') {
      this.width = 1;
      this.height = 1;
      this.data = new Float16Array([0.02, 0.03, 0.05, 1.0]);
      this.loaded = this._load(url);
    } else {
      this.data = url; // Assume pre-filled array
      this.loaded = Promise.resolve();
    }
  }

  async _load(url) {
    try {
      const response = await fetch(url);
      if (!response.ok) throw new Error(`HTTP error! status: ${response.status}`);
      
      const arrayBuffer = await response.arrayBuffer();
      // parse-hdr expects a Uint8Array
      const hdr = parseHdr(new Uint8Array(arrayBuffer));
      this.hdrData = hdr.data;
      
      this.width = hdr.shape[0];
      this.height = hdr.shape[1];
      
      this.updateData();
      return this;
    } catch (err) {
      console.error("Failed to load HDR:", url, err);
      // Return a 1x1 black fallback so the engine doesn't crash
      this.width = 1; this.height = 1;
      this.data = new Float16Array([0.01, 0, 0, 1]);
      return this;
    }
  }

  async updateData() {
    const hdrData = this.hdrData;
    if (!hdrData) return;
    // Convert RGB (3 floats) to RGBA (4 floats) for WebGPU compatibility
    this.data = new Float16Array(this.width * this.height * 4);
    for (let i = 0; i < this.width * this.height; i++) {
      this.data[i * 4 + 0] = Math.min(hdrData[i * 4 + 0] * this.exposure, this.threshold);
      this.data[i * 4 + 1] = Math.min(hdrData[i * 4 + 1] * this.exposure, this.threshold);
      this.data[i * 4 + 2] = Math.min(hdrData[i * 4 + 2] * this.exposure, this.threshold);
      this.data[i * 4 + 3] = 1.0; // Alpha channel
    }
  }
  
  generateThumbnail(size = 256) {
    if (this.thumbnailURL[size]) return this.thumbnailURL[size];
    if (!this.data || !this.width || !this.height) return "";

    // 1. Calculate downsampled dimensions
    const scale = Math.min(size / this.width, size / this.height, 1.0);
    const thumbW = Math.floor(this.width * scale);
    const thumbH = Math.floor(this.height * scale);

    const rgba = new Uint8ClampedArray(thumbW * thumbH * 4);

    // 2. Sample data with Tone Mapping
    for (let y = 0; y < thumbH; y++) {
      for (let x = 0; x < thumbW; x++) {
        // Map thumbnail pixel back to source data pixel
        const srcX = Math.floor(x / scale);
        const srcY = Math.floor(y / scale);
        const srcIdx = (srcY * this.width + srcX) * 4;
        const dstIdx = (y * thumbW + x) * 4;

        for (let c = 0; c < 3; c++) {
          let val = this.data[srcIdx + c] * this.exposure;
          // Reinhard Tone Mapping
          val = val / (1.0 + val);
          // Gamma Correction
          val = Math.pow(val, 1.0 / 2.2);
          rgba[dstIdx + c] = Math.max(0, Math.min(255, val * 255));
        }
        rgba[dstIdx + 3] = 255;
      }
    }

    // 3. Create canvas and return small DataURL
    const canvas = document.createElement('canvas');
    canvas.width = thumbW;
    canvas.height = thumbH;
    const ctx = canvas.getContext('2d');
    
    const imgData = new ImageData(rgba, thumbW, thumbH);
    ctx.putImageData(imgData, 0, 0);

    const url = canvas.toDataURL("image/png");
    this.thumbnailURL[size] = url;
    return url;
  }

  buildHDRCDF() {
    const { width, height, data } = this; 

    // Sizes:
    // margCDF takes (height + 1) elements
    // condCDF takes height * (width + 1) elements
    const margSize = height + 1;
    const condSize = height * (width + 1);
    
    // Single unified buffer
    const skyCDF = new Float32Array(margSize + condSize);
    
    // Let's place margCDF at the very beginning (index 0)
    const margCDF = skyCDF.subarray(0, margSize);
    // Let's place condCDF right after it
    const condCDF = skyCDF.subarray(margSize, margSize + condSize);

    let totalWeight = 0;

    margCDF[0] = 0;

    for (let y = 0; y < height; y++) {
      let rowWeight = 0;
      const sinTheta = Math.sin(Math.PI * (y + 0.5) / height);
      
      condCDF[y * (width + 1)] = 0;
      
      for (let x = 0; x < width; x++) {
        const idx = (y * width + x) * 4;
        const r = Math.min(data[idx] * this.exposure, this.threshold);
        const g = Math.min(data[idx + 1] * this.exposure, this.threshold);
        const b = Math.min(data[idx + 2] * this.exposure, this.threshold);
        
        const lum = (0.2126 * r + 0.7152 * g + 0.0722 * b) * sinTheta;
        
        rowWeight += lum;
        condCDF[y * (width + 1) + x + 1] = rowWeight;
      }

      if (rowWeight > 0) {
        for (let x = 1; x <= width; x++) {
          condCDF[y * (width + 1) + x] /= rowWeight;
        }
      } else {
        for (let x = 1; x <= width; x++) {
          condCDF[y * (width + 1) + x] = x / width;
        }
      }

      totalWeight += rowWeight;
      margCDF[y + 1] = totalWeight;
    }

    if (totalWeight > 0) {
      for (let y = 1; y <= height; y++) {
        margCDF[y] /= totalWeight;
      }
    } else {
      for (let y = 1; y <= height; y++) {
        margCDF[y] = y / height;
      }
    }

    // Pass `skyCDF` to your GPU buffer, and record where the conditional CDF starts
    return { 
      skyCDF, 
      sky_cdf_index: margSize, // This is the offset where condCDF begins!
      totalWeight 
    };
  }

}

class Material {
  constructor(name, color = [1, 1, 1], roughness = 0.5, options = {}) {
    this.id = 'material_' + Math.random().toString(36).substring(2, 9);
    this.name = name || "New Material";

    // --- Core PBR ---
    this.color = color;               // baseColor
    this.roughness = roughness;       // roughness
    this.metallic = options.metallic !== undefined ? options.metallic : 0.0;
    this.ior = options.ior || 1.5;
    
    // --- Emission ---
    this.emittance = options.emittance || [1, 1, 1];
    this.emissionIntensity = options.emissionIntensity || 0.0;

    // --- Disney Layers ---
    this.subsurface = options.subsurface || 0.0;
    this.subsurfaceTint = options.subsurfaceTint || [...this.color];
    this.specularTint = options.specularTint || 0.0;
    this.anisotropic = options.anisotropic || 0.0;
    this.anisotropicRotation = options.anisotropicRotation || 0.0;
    this.sheen = options.sheen || 0.0;
    this.sheenTint = options.sheenTint || 0.5;
    this.clearcoat = options.clearcoat || 0.0;
    this.clearcoatGloss = options.clearcoatGloss || 1.0; // Roughness of CC
    this.clearcoatIor = options.clearcoatIor || 1.5;
    this.transmission = options.transmission || 0.0;
    this.concentration = options.concentration || 1.0;

    // --- Texture Support ---
    this.emissiveTex = options.emissiveTex || null;
    this.albedoTex = options.albedoTex || null;
    this.normalTex = options.normalTex || null;
    this.heightTex = options.heightTex || null;
    this.roughnessTex = options.roughnessTex || null;
    this.metallicTex = options.metallicTex || null;

    // --- Texture/POM Params ---
    this.uvScale = options.uvScale || [1, 1];
    this.normalMultiplier = options.normalMultiplier || 1.0;
    this.heightMultiplier = options.heightMultiplier !== undefined ? options.heightMultiplier : 0.05;
    this.heightSamp = options.heightSamp || 32;
    this.heightOffset = options.heightOffset || 0.0;

    // --- Physics Params ---
    this.density = options.density || 5;
    this.friction = options.friction !== undefined ? options.friction : 0.5;
    this.restitution = options.restitution !== undefined ? options.restitution : 0;
  }
}
Material.getSchema = function(m) {
  if (!m) m = new Material("name",[1,1,1],1.0);
  const getIdx = (tex) => (tex && tex.texIndex !== undefined) ? tex.texIndex : -1;
  return [
    { type: "vec3f", data: m.color.map(v => Math.pow(v, 2.2)) },
    { type: "f32", data: m.metallic },

    { type: "f32", data: m.roughness },
    { type: "f32", data: m.ior },
    { type: "f32", data: m.specularTint },
    { type: "f32", data: m.anisotropic },

    { type: "f32", data: m.anisotropicRotation },
    { type: "f32", data: m.sheen },
    { type: "f32", data: m.sheenTint },
    { type: "f32", data: m.clearcoat },

    { type: "f32", data: m.clearcoatGloss },
    { type: "f32", data: m.clearcoatIor },
    { type: "f32", data: m.transmission },
    { type: "f32", data: m.concentration },

    { type: "vec3f", data: m.subsurfaceTint.map(v => Math.pow(v, 2.2)) },
    { type: "f32", data: m.subsurface },

    { type: "vec3f", data: m.emittance.map(v => v * m.emissionIntensity) },
    { type: "i32", data: getIdx(m.emissiveTex) },

    { type: "i32", data: getIdx(m.albedoTex) },
    { type: "i32", data: getIdx(m.normalTex) },
    { type: "i32", data: getIdx(m.heightTex) },

    { type: "i32", data: getIdx(m.roughnessTex) },
    { type: "i32", data: getIdx(m.metallicTex) },
    { padding: true },
    { type: "vec2f", data: m.uvScale },
    
    { type: "vec4f", data: [m.normalMultiplier, m.heightMultiplier, m.heightSamp, m.heightOffset] },
  ];
}

// Helper to transform an AABB by a matrix
function transformAABB(localMin, localMax, worldMatrix) {
  const corners = [];
  for (let x of [localMin[0], localMax[0]]) {
    for (let y of [localMin[1], localMax[1]]) {
      for (let z of [localMin[2], localMax[2]]) {
        const p = vec3.fromValues(x, y, z);
        vec3.transformMat4(p, p, worldMatrix);
        corners.push(p);
      }
    }
  }
  const min = vec3.fromValues(Infinity, Infinity, Infinity);
  const max = vec3.fromValues(-Infinity, -Infinity, -Infinity);
  for (let c of corners) {
    vec3.min(min, min, c);
    vec3.max(max, max, c);
  }
  return { min, max };
}

class Primitive {
  constructor(name,material,type) {
    this.id = 'obj_' + Math.random().toString(36).substr(2, 9);
    this.name = name || ("New " + type);
    this.type = type;
    this.icon = "📦";

    this.material = material;
    this.position = vec3.create();
    this.velocity = vec3.create();
    this.scale = vec3.fromValues(1, 1, 1);
    this.rotation = quat.create(); 
    this.angularVelocity = vec3.create();
    this.matrix = mat4.create();
    this.invMatrix = mat4.create();

    this.enableNEE = false;
    this.lightIdx = -1;

    this.vaoData = null; 
    this.needsMeshUpdate = true;
  }

  updatePreview(gl) {
    if (!this.needsMeshUpdate) return;
    const mesh = this.generateMesh();
    // Assuming window.createVAO exists to handle gl.bufferData
    if (this.vaoData) { /* cleanup old buffers here if needed */ }
    this.vaoData = window.createVAOWithBuffers(mesh.p, mesh.n, mesh.i, mesh.u);
    this.needsMeshUpdate = false;
  }

  // To be overridden by children
  generateMesh() { return { p:[], n:[], u:[], i:[] }; }
  getArea() { return 0; }

  translate(x, y, z) {
    vec3.add(this.position, this.position, [x, y, z]);
    this.updateMatrix();
    return this; // Allows chaining: p.translate(1,0,0).scale(2,2,2)
  }

  scaleMult(x, y, z) {
    vec3.multiply(this.scale, this.scale, [x, y, z]);
    this.updateMatrix();
    return this; 
  }

  scaleSet(x, y, z) {
    // If only one argument is provided, scale uniformly
    if (y === undefined) y = z = x;
    vec3.set(this.scale, x, y, z);
    this.updateMatrix();
    return this;
  }

  // Rotates around the X axis (theta in radians)
  rotateX(theta) {
    quat.rotateX(this.rotation, this.rotation, theta);
    this.updateMatrix();
    return this;
  }

  // Rotates around the Y axis
  rotateY(theta) {
    quat.rotateY(this.rotation, this.rotation, theta);
    this.updateMatrix();
    return this;
  }

  // Rotates around the Z axis
  rotateZ(theta) {
    quat.rotateZ(this.rotation, this.rotation, theta);
    this.updateMatrix();
    return this;
  }

  // Rotate by theta around an arbitrary axis [ax, ay, az]
  rotate(theta, ax, ay, az) {
    const axis = vec3.fromValues(ax, ay, az);
    vec3.normalize(axis, axis);
    quat.setAxisAngle(this.rotation, axis, theta);
    this.updateMatrix();
    return this;
  }

  // Handy helper to set position directly
  setPosition(x, y, z) {
    vec3.set(this.position, x, y, z);
    this.updateMatrix();
    return this;
  }

  // Matrix
  updateMatrix() {
    mat4.fromRotationTranslationScale(this.matrix, this.rotation, this.position, this.scale);
    mat4.invert(this.invMatrix, this.matrix);
  }

  getBounds() {
    const worldMatrix = mat4.create();
    mat4.invert(worldMatrix, this.invMatrix);
    // Unit sphere is -1 to 1 in local space
    return transformAABB([-1,-1,-1], [1,1,1], worldMatrix);
  }
}

class Sphere extends Primitive {
  constructor(name,material, x=0, y=0, z=0, radius=1) {
    super(name,material,"Sphere");
    this.icon = "⚽";
    vec3.set(this.position, x, y, z);
    vec3.set(this.scale, radius, radius, radius);
    this.updateMatrix();
  }
  generateMesh(segs = 32) {
    const p = [], n = [], u = [], i = [];
    for (let y = 0; y <= segs; y++) {
      const v = y / segs, phi = v * Math.PI;
      for (let x = 0; x <= segs; x++) {
        const uVal = x / segs, theta = uVal * Math.PI * 2;
        const nx = Math.sin(phi) * Math.cos(theta);
        const ny = Math.cos(phi);
        const nz = Math.sin(phi) * Math.sin(theta);
        p.push(nx, ny, nz); // Local unit sphere, scale handles the rest
        n.push(nx, ny, nz);
        u.push(uVal, v);
      }
    }
    for (let y = 0; y < segs; y++) {
      for (let x = 0; x < segs; x++) {
        const a = y * (segs + 1) + x, b = a + 1, c = a + (segs + 1), d = c + 1;
        i.push(a, b, d, a, d, c);
      }
    }
    return { p, n, u, i };
  }
  getArea() {
    var radius = (this.scale[0]+this.scale[1]+this.scale[2])/3;
    return 4 * Math.PI * radius * radius;
  }
  getBounds() {
    const m = this.matrix;

    // The half-extents of a transformed sphere (ellipsoid) 
    // are the lengths of the basis vectors of the transformation.
    const ex = Math.sqrt(m[0]*m[0] + m[4]*m[4] + m[8]*m[8]);
    const ey = Math.sqrt(m[1]*m[1] + m[5]*m[5] + m[9]*m[9]);
    const ez = Math.sqrt(m[2]*m[2] + m[6]*m[6] + m[10]*m[10]);

    const center = vec3.fromValues(m[12], m[13], m[14]);

    return {
      min: vec3.fromValues(center[0] - ex, center[1] - ey, center[2] - ez),
      max: vec3.fromValues(center[0] + ex, center[1] + ey, center[2] + ez)
    };
  }
}
Sphere.getSchema = function(sphere) {
  if (!sphere) sphere = {material:{_index:-1}};
  return [
    { type:"mat4x4f", data: sphere.invMatrix },
    { type:"i32", data: sphere.material._index },
    { type:"i32", data: sphere.lightIdx },
    { type:"i32", data: 1 },
    { padding: true },
    { type:"vec3f", data: sphere.position },
    { padding: true },
  ];
}

class Cube extends Primitive {
  constructor(name,material, minX=-1, minY=-1, minZ=-1, maxX=1, maxY=1, maxZ=1) {
    super(name,material,"Cube");
    this.icon = "🧊";
    vec3.set(this.position, (minX + maxX) / 2, (minY + maxY) / 2, (minZ + maxZ) / 2);
    vec3.set(this.scale, (maxX - minX) / 2, (maxY - minY) / 2, (maxZ - minZ) / 2);
    this.updateMatrix();
  }
  getArea() {
    var s = this.scale;
    return 8*(s[0]*s[1]+s[1]*s[2]+s[0]*s[2]);
  }
  generateMesh() {
    // Standard cube with 24 vertices to allow distinct normals/UVs per face
    const p = [
      -1,-1, 1,  1,-1, 1,  1, 1, 1, -1, 1, 1, // Front
      -1,-1,-1, -1, 1,-1,  1, 1,-1,  1,-1,-1, // Back
      -1, 1,-1, -1, 1, 1,  1, 1, 1,  1, 1,-1, // Top
      -1,-1,-1,  1,-1,-1,  1,-1, 1, -1,-1, 1, // Bottom
       1,-1,-1,  1, 1,-1,  1, 1, 1,  1,-1, 1, // Right
      -1,-1,-1, -1,-1, 1, -1, 1, 1, -1, 1,-1  // Left
    ];
    const n = [
      0,0,1, 0,0,1, 0,0,1, 0,0,1,  0,0,-1, 0,0,-1, 0,0,-1, 0,0,-1,
      0,1,0, 0,1,0, 0,1,0, 0,1,0,  0,-1,0, 0,-1,0, 0,-1,0, 0,-1,0,
      1,0,0, 1,0,0, 1,0,0, 1,0,0, -1,0,0, -1,0,0, -1,0,0, -1,0,0
    ];
    const u = [];
    for(let f=0; f<6; f++) u.push(0,0, 1,0, 1,1, 0,1);
    const i = [];
    for(let f=0; f<6; f++) { const o = f*4; i.push(o, o+1, o+2, o, o+2, o+3); }
    return { p, n, u, i };
  }
}
Cube.getSchema = function(cube) {
  if (!cube) cube = {material:{_index:-1}};
  return [
    { type:"mat4x4f", data: cube.invMatrix },
    { type:"i32", data: cube.material._index },
    { type:"i32", data: cube.lightIdx },
    { type:"i32", data: 2 },
    { padding: true },
    { type:"vec3f", data: cube.position },
    { padding: true },
  ];
}

class Cylinder extends Primitive {
  constructor(name, material, top_radius = 0.5) {
    super(name, material,"Cylinder");
    this.icon = "🛢️";
    this.top_radius = top_radius; // In this context, it will act as a ratio
  }

  orient(x1, y1, z1, r1, x2, y2, z2, r2) {
    const p1 = vec3.fromValues(x1, y1, z1);
    const p2 = vec3.fromValues(x2, y2, z2);
    const dir = vec3.create();

    // 1. Determine which end is the "Base" (y=0)
    // We want the wider end to be the base so top_radius is always <= 1.0
    if (r1 >= r2) {
      vec3.set(this.position, x1, y1, z1); // Start at P1
      vec3.subtract(dir, p2, p1);          // Point toward P2
      const h = vec3.length(dir);
      vec3.set(this.scale, r1, h, r1);     // Width is r1, height is distance
      this.top_radius = (r1 > 0) ? r2 / r1 : 0;
    } else {
      vec3.set(this.position, x2, y2, z2); // Start at P2
      vec3.subtract(dir, p1, p2);          // Point toward P1
      const h = vec3.length(dir);
      vec3.set(this.scale, r2, h, r2);     // Width is r2, height is distance
      this.top_radius = (r2 > 0) ? r1 / r2 : 0;
    }

    // 2. Align Local Y (0,1,0) to the segment direction
    const dist = vec3.length(dir);
    if (dist > 1e-6) {
      vec3.normalize(dir, dir);
      quat.rotationTo(this.rotation, [0, 1, 0], dir);
    } else {
      quat.identity(this.rotation);
    }

    this.updateMatrix();
    return this;
  }
  
  generateMesh(segs = 32) {
    const p = [], n = [], u = [], i = [];
    const bottom = 0;
    const top = 1;
    const radiusBottom = 1;
    const radiusTop = this.top_radius;

    // --- 1. Side Walls ---
    // We double the vertices at the seam (x=0 and x=segs) to prevent UV bleeding
    for (let y = 0; y <= 1; y++) {
      const r = (y === 0) ? radiusBottom : radiusTop;
      const py = (y === 0) ? bottom : top;
      for (let x = 0; x <= segs; x++) {
        const uVal = x / segs;
        const theta = uVal * Math.PI * 2;
        const cos = Math.cos(theta);
        const sin = Math.sin(theta);
        
        p.push(r * cos, py, r * sin);
        n.push(cos, 0, sin); 
        u.push(uVal, y);
      }
    }
    for (let x = 0; x < segs; x++) {
      const a = x, b = x + 1, c = x + (segs + 1), d = c + 1;
      i.push(a, b, d, a, d, c);
    }

    // --- 2. Bottom Cap (y = bottom) ---
    let offset = p.length / 3;
    p.push(0, bottom, 0); n.push(0, -1, 0); u.push(0.5, 0.5); // Center
    for (let x = 0; x <= segs; x++) {
      const theta = (x / segs) * Math.PI * 2;
      const cos = Math.cos(theta), sin = Math.sin(theta);
      p.push(radiusBottom * cos, bottom, radiusBottom * sin);
      n.push(0, -1, 0);
      u.push(0.5 + cos * 0.5, 0.5 + sin * 0.5);
      if (x < segs) i.push(offset, offset + x + 2, offset + x + 1);
    }

    // --- 3. Top Cap (y = top) ---
    offset = p.length / 3;
    p.push(0, top, 0); n.push(0, 1, 0); u.push(0.5, 0.5); // Center
    for (let x = 0; x <= segs; x++) {
      const theta = (x / segs) * Math.PI * 2;
      const cos = Math.cos(theta), sin = Math.sin(theta);
      p.push(radiusTop * cos, top, radiusTop * sin);
      n.push(0, 1, 0);
      u.push(0.5 + cos * 0.5, 0.5 + sin * 0.5);
      if (x < segs) i.push(offset, offset + x + 1, offset + x + 2);
    }

    return { p, n, u, i };
  }

  // getBounds() {
  //   const worldMatrix = mat4.create();
  //   mat4.invert(worldMatrix, this.invMatrix);
  //   // Cylinder is defined y=0 to y=1, and x/z depends on radii
  //   const maxR = this.top_radius;
  //   return transformAABB([-maxR, 0, -maxR], [maxR, 1, maxR], worldMatrix);
  // }
  getBounds() {
    const m = this.matrix; 

    const getCircleAABB = (yLocal, radius) => {
      // Correctly access the basis vectors: 
      // Column 0 (m[0,1,2]) is Local X
      // Column 2 (m[8,9,10]) is Local Z
      const ex = Math.sqrt(Math.pow(radius * m[0], 2) + Math.pow(radius * m[8], 2));
      const ey = Math.sqrt(Math.pow(radius * m[1], 2) + Math.pow(radius * m[9], 2));
      const ez = Math.sqrt(Math.pow(radius * m[2], 2) + Math.pow(radius * m[10], 2));

      const worldCenter = vec3.transformMat4(vec3.create(), vec3.fromValues(0, yLocal, 0), m);

      return {
        min: vec3.fromValues(worldCenter[0] - ex, worldCenter[1] - ey, worldCenter[2] - ez),
        max: vec3.fromValues(worldCenter[0] + ex, worldCenter[1] + ey, worldCenter[2] + ez)
      };
    };

    const b = getCircleAABB(0, 1);
    const t = getCircleAABB(1, this.top_radius);

    // Final Union
    const finalMin = vec3.create();
    const finalMax = vec3.create();
    vec3.min(finalMin, b.min, t.min);
    vec3.max(finalMax, b.max, t.max);

    return { min: finalMin, max: finalMax };
  }
}
Cylinder.getSchema = function(cylinder) {
  if (!cylinder) cylinder = {material:{_index:-1}};
  return [
    { type: "mat4x4f", data: cylinder.invMatrix },
    { type: "i32", data: cylinder.material._index },
    { type: "i32", data: cylinder.lightIdx },
    { type: "i32", data: 3 },
    { type: "f32", data: cylinder.top_radius },
    { type: "vec3f", data: cylinder.position },
    { padding: true },
  ];
}

class Torus extends Primitive {
  constructor(name, material, outerRadius = 1.0, innerRadius = 0.3) {
    super(name,material,"Torus");
    this.icon = "🍩";
    this.setRadii(outerRadius, innerRadius);
  }

  setRadii(outer, inner) {
    // We fix the local Outer Radius (R) to 1.0
    // So we scale the entire object by 'outer'
    this.scaleSet(outer, outer, outer);
    
    // The inner radius (r) must be stored as a ratio relative to the outer radius
    this.inner_radius = inner / outer; 
    return this;
  }

  generateMesh(radSegs = 32, tubSegs = 16) {
    const p = [], n = [], u = [], i = [];
    const r = this.inner_radius; 
    const R = 1.0; // Major radius normalized
    for (let j = 0; j <= tubSegs; j++) {
      for (let k = 0; k <= radSegs; k++) {
        const uVal = k / radSegs, vVal = j / tubSegs;
        const theta = uVal * Math.PI * 2, phi = vVal * Math.PI * 2;
        const x = (R + r * Math.cos(phi)) * Math.cos(theta);
        const y = r * Math.sin(phi);
        const z = (R + r * Math.cos(phi)) * Math.sin(theta);
        p.push(x, y, z);
        n.push(Math.cos(phi)*Math.cos(theta), Math.sin(phi), Math.cos(phi)*Math.sin(theta));
        u.push(uVal, vVal);
      }
    }
    for (let j = 0; j < tubSegs; j++) {
      for (let k = 0; k < radSegs; k++) {
        const a = j * (radSegs + 1) + k, b = a + 1, c = a + (radSegs + 1), d = c + 1;
        i.push(a, b, d, a, d, c);
      }
    }
    return { p, n, u, i };
  }

  // getBounds() {
  //   const worldMatrix = mat4.create();
  //   mat4.invert(worldMatrix, this.invMatrix);
  //   // Torus lies in XZ plane. Local bounds:
  //   const r = 1 + this.inner_radius;
  //   return transformAABB([-r, -this.inner_radius, -r], [r, this.inner_radius, r], worldMatrix);
  // }
  getBounds() {
    const m = this.matrix; // Local to World
    const R = 1.0;            // Major Radius (per your prompt)
    const r = this.inner_radius; // Minor Radius (thickness)

    // 1. Calculate the AABB of the Major Ring (the central spine of the torus)
    // This is an analytical ellipse in 3D space.
    const ex = Math.sqrt(Math.pow(R * m[0], 2) + Math.pow(R * m[8], 2));
    const ey = Math.sqrt(Math.pow(R * m[1], 2) + Math.pow(R * m[9], 2));
    const ez = Math.sqrt(Math.pow(R * m[2], 2) + Math.pow(R * m[10], 2));

    const worldCenter = vec3.transformMat4(vec3.create(), vec3.fromValues(0, 0, 0), m);

    // 2. Expand the Ellipse AABB by the Minor Radius 'r'
    // Since the minor radius extends in all directions from the ring, 
    // we must account for how 'r' projects into world space.
    
    // To be perfectly tight, we find the maximum scale of the matrix 
    // to ensure the 'thickness' is correctly represented if scaled.
    const scaleX = Math.sqrt(m[0]*m[0] + m[1]*m[1] + m[2]*m[2]);
    const scaleY = Math.sqrt(m[4]*m[4] + m[5]*m[5] + m[6]*m[6]);
    const scaleZ = Math.sqrt(m[8]*m[8] + m[9]*m[9] + m[10]*m[10]);
    const maxScale = Math.max(scaleX, scaleY, scaleZ);
    
    const thickness = r * maxScale;

    return {
      min: vec3.fromValues(
        worldCenter[0] - ex - thickness, 
        worldCenter[1] - ey - thickness, 
        worldCenter[2] - ez - thickness
      ),
      max: vec3.fromValues(
        worldCenter[0] + ex + thickness, 
        worldCenter[1] + ey + thickness, 
        worldCenter[2] + ez + thickness
      )
    };
  }
}
Torus.getSchema = function(torus) {
  if (!torus) torus = {material:{_index:-1}, inner_radius: 0};
  return [
    { type: "mat4x4f", data: torus.invMatrix },
    { type: "i32", data: torus.material._index },
    { type: "i32", data: torus.lightIdx },
    { type: "i32", data: 4 },
    { type: "f32", data: torus.inner_radius },
    { type: "vec3f", data: torus.position },
    { padding: true },
  ];
}

class Plane extends Primitive {
  constructor(name,material, nx=0, ny=1, nz=0, d=0) {
    super(name,material,"Plane")
    this.material = material;
    this.orient(nx,ny,nz,d);
    this.icon = "✈️"
  }
  getBounds() {
    return {max:[0,0,0],min:[0,0,0]};
  }
  orient(nx, ny, nz, d) {
    const targetNormal = vec3.normalize(vec3.create(), [nx, ny, nz]);
    vec3.scale(this.position, targetNormal, d);
    const localUp = vec3.fromValues(0, 1, 0);
    quat.rotationTo(this.rotation, localUp, targetNormal);
    this.updateMatrix();
    return this;
  }
  getOrientation() {
    const worldNormal = vec3.fromValues(0, 1, 0);
    vec3.transformQuat(worldNormal, worldNormal, this.rotation);
    const d = vec3.dot(this.position, worldNormal);
    return { normal: worldNormal, d: d };
  }
  // generateMesh() {
  //   const size = 1000;
  //   const p = [ -size, 0, -size,  size, 0, -size,  size, 0, size, -size, 0, size ];
  //   const n = [ 0, 1, 0,  0, 1, 0,  0, 1, 0,  0, 1, 0 ];
  //   const u = [ 0, 0,  size/10, 0,  size/10, size/10, 0, size/10 ];
  //   const i = [0, 1, 2, 0, 2, 3];
  //   return { p, n, u, i };
  // }
  generateMesh() {
    const p = [], n = [], u = [], i = [];
    const res = 100;    // Central grid resolution
    const size = 100;   // Central grid total size (units)
    const far = 10000;  // "Infinite" distance
    const step = size / res;
    const half = size / 2;

    // 1. GENERATE CENTRAL TILED GRID
    for (let z = 0; z <= res; z++) {
      for (let x = 0; x <= res; x++) {
        const posX = x * step - half;
        const posZ = z * step - half;
        p.push(posX, 0, posZ);
        n.push(0, 1, 0);
        u.push(posX, posZ); // Tiled UVs (1 unit = 1 repeat)
      }
    }

    // Generate indices for the central grid
    for (let z = 0; z < res; z++) {
      for (let x = 0; x < res; x++) {
        const r1 = z * (res + 1);
        const r2 = (z + 1) * (res + 1);
        i.push(r1 + x, r1 + x + 1, r2 + x);
        i.push(r1 + x + 1, r2 + x + 1, r2 + x);
      }
    }

    // 2. GENERATE HORIZON SKIRT (The "Infinite" Edges)
    const gridCount = p.length / 3;
    
    // Add 4 Far Vertices (Corners of the universe)
    // All UVs set to 0.5, 0.5 as requested
    const farCoords = [
      [-far, 0, -far], [far, 0, -far], 
      [far, 0, far], [-far, 0, far]
    ];
    
    farCoords.forEach(coords => {
      p.push(...coords);
      n.push(0, 1, 0);
      u.push(0.5, 0.5); 
    });

    const idxNW = gridCount, idxNE = gridCount + 1, idxSE = gridCount + 2, idxSW = gridCount + 3;

    // Stitch North Edge (z = 0) to Far North points
    for (let x = 0; x < res; x++) {
      const v1 = x;
      const v2 = x + 1;
      i.push(v1, idxNW, v2);
      i.push(v2, idxNW, idxNE);
    }

    // Stitch South Edge (z = res) to Far South points
    const sStart = res * (res + 1);
    for (let x = 0; x < res; x++) {
      const v1 = sStart + x;
      const v2 = sStart + x + 1;
      i.push(v1, v2, idxSW);
      i.push(v2, idxSE, idxSW);
    }

    // Stitch West Edge (x = 0)
    for (let z = 0; z < res; z++) {
      const v1 = z * (res + 1);
      const v2 = (z + 1) * (res + 1);
      i.push(v1, v2, idxNW);
      i.push(v2, idxSW, idxNW);
    }

    // Stitch East Edge (x = res)
    for (let z = 0; z < res; z++) {
      const v1 = z * (res + 1) + res;
      const v2 = (z + 1) * (res + 1) + res;
      i.push(v1, idxNE, v2);
      i.push(v2, idxNE, idxSE);
    }

    return { p, n, u, i };
  }
}
Plane.getSchema = function(plane) {
  const orientation = plane ? plane.getOrientation() : { d: 0, normal: [0,0,0] };
  if (!plane) plane = {material:{_index:-1}};
  return [
    { type:"vec3f", data: orientation.normal },
    { type:"f32", data: orientation.d },
    { type:"i32", data: plane.material._index },
  ];
}

class ModelData {
  constructor(name) {
    this.id = 'model_' + Math.random().toString(36).substr(2, 9);
    this.name = name || "New Model";

    // Core geometry data stored in flat typed arrays
    this.vertex_positions = new Float32Array(0);
    this.vertex_normals = new Float32Array(0);
    this.vertex_texcoords = new Float32Array(0);

    // Indices for topology
    this.index_positions = new Uint32Array(0);
    this.index_normals = new Uint32Array(0);
    this.index_texcoords = new Uint32Array(0);

    this.triangles = []; // Initial raw triangles
    this.nodes = [];     // Final flattened BVH nodes [{min, max, num_triangles, next}]
    this.flatTriangles = []; // Final sorted triangles [{v0, v1, v2, n0, n1, n2, u0, u1, u2}]

    this.glData = null;
  }

  loadOBJ(url,onload) {
    this.loaded = (async () => {
      try {
        const res = await fetch(url);
        const txt = await res.text();
        this.parseOBJ(txt);
        if (onload) onload(this);
      } catch (e) {
        console.error("Model load failed:", e);
      }
      return this;
    })();
    return this;
  }

  parseOBJ(txt) {
    const lines = txt.split('\n');
    const positions = [];
    const uvs = [];
    const normals = [];
    const f_p = [], f_u = [], f_n = [];

    for (const line of lines) {
      const parts = line.trim().split(/\s+/);
      const type = parts[0];
      if (type === 'v') positions.push(parseFloat(parts[1]), parseFloat(parts[2]), parseFloat(parts[3]));
      else if (type === 'vt') uvs.push(parseFloat(parts[1]), parseFloat(parts[2]));
      else if (type === 'vn') normals.push(parseFloat(parts[1]), parseFloat(parts[2]), parseFloat(parts[3]));
      else if (type === 'f') {
        const face = parts.slice(1).map(p => {
          const idx = p.split('/');
          return {
            v: parseInt(idx[0]) - 1,
            u: idx[1] ? parseInt(idx[1]) - 1 : -1,
            n: idx[2] ? parseInt(idx[2]) - 1 : -1
          };
        });
        // Simple triangulation for N-gons
        for (let i = 1; i < face.length - 1; i++) {
          f_p.push(face[0].v, face[i].v, face[i+1].v);
          f_u.push(face[0].u, face[i].u, face[i+1].u);
          f_n.push(face[0].n, face[i].n, face[i+1].n);
        }
      }
    }

    this.vertex_positions = new Float32Array(positions);
    this.vertex_normals = new Float32Array(normals);
    this.vertex_texcoords = new Float32Array(uvs);
    this.index_positions = new Int32Array(f_p);
    this.index_normals = new Int32Array(f_n);
    this.index_texcoords = new Int32Array(f_u);
    return this;
  }

  generateTriangles() {
    const triCount = this.index_positions.length / 3;
    this.triangles = new Array(triCount);

    for (let i = 0; i < triCount; i++) {
      const i3 = i * 3;
      
      // Get indices for this triangle
      const ip = [this.index_positions[i3], this.index_positions[i3+1], this.index_positions[i3+2]];
      const inorm = [this.index_normals[i3], this.index_normals[i3+1], this.index_normals[i3+2]];
      const iuv = [this.index_texcoords[i3], this.index_texcoords[i3+1], this.index_texcoords[i3+2]];

      const tri = {
        v0: [this.vertex_positions[ip[0]*3], this.vertex_positions[ip[0]*3+1], this.vertex_positions[ip[0]*3+2]],
        v1: [this.vertex_positions[ip[1]*3], this.vertex_positions[ip[1]*3+1], this.vertex_positions[ip[1]*3+2]],
        v2: [this.vertex_positions[ip[2]*3], this.vertex_positions[ip[2]*3+1], this.vertex_positions[ip[2]*3+2]],
        
        n0: [this.vertex_normals[inorm[0]*3], this.vertex_normals[inorm[0]*3+1], this.vertex_normals[inorm[0]*3+2]],
        n1: [this.vertex_normals[inorm[1]*3], this.vertex_normals[inorm[1]*3+1], this.vertex_normals[inorm[1]*3+2]],
        n2: [this.vertex_normals[inorm[2]*3], this.vertex_normals[inorm[2]*3+1], this.vertex_normals[inorm[2]*3+2]],
        
        u0: [this.vertex_texcoords[iuv[0]*2], this.vertex_texcoords[iuv[0]*2+1]],
        u1: [this.vertex_texcoords[iuv[1]*2], this.vertex_texcoords[iuv[1]*2+1]],
        u2: [this.vertex_texcoords[iuv[2]*2], this.vertex_texcoords[iuv[2]*2+1]]
      };

      tri.centroid = [
        (tri.v0[0] + tri.v1[0] + tri.v2[0]) / 3,
        (tri.v0[1] + tri.v1[1] + tri.v2[1]) / 3,
        (tri.v0[2] + tri.v1[2] + tri.v2[2]) / 3
      ];

      this.triangles[i] = tri;
    }
  }

  generateBVH() {
    this.glData = null;
    this.generateTriangles();
    const triCentroids = this.triangles.map(t => t.centroid);
    const triIndices = this.triangles.map((_, i) => i);

    const getBounds = (indices) => {
      let min = [Infinity, Infinity, Infinity], max = [-Infinity, -Infinity, -Infinity];
      for (const idx of indices) {
        const t = this.triangles[idx];
        const verts = [t.v0, t.v1, t.v2];
        for (const v of verts) {
          for (let k = 0; k < 3; k++) {
            min[k] = Math.min(min[k], v[k]);
            max[k] = Math.max(max[k], v[k]);
          }
        }
      }
      return { min, max };
    };

    const getArea = (min, max) => {
      const d = [max[0]-min[0], max[1]-min[1], max[2]-min[2]];
      return 2 * (d[0]*d[1] + d[1]*d[2] + d[2]*d[0]);
    };

    const subdivide = (indices) => {
      const { min, max } = getBounds(indices);
      const rootArea = getArea(min, max);
      let bestCost = indices.length * rootArea;
      let bestAxis = -1, bestSplit = -1;

      // SAH Evaluation
      for (let axis = 0; axis < 3; axis++) {
        const start = min[axis], end = max[axis];
        if (end - start < 1e-6) continue;

        const numBins = Math.min(indices.length, 12);
        for (let i = 1; i < numBins; i++) {
          const split = start + (i / numBins) * (end - start);
          let left = [], right = [];
          for (const idx of indices) {
            if (triCentroids[idx][axis] < split) left.push(idx); else right.push(idx);
          }
          if (left.length === 0 || right.length === 0) continue;
          
          const bL = getBounds(left), bR = getBounds(right);
          const cost = left.length * getArea(bL.min, bL.max) + right.length * getArea(bR.min, bR.max);
          if (cost < bestCost) {
            bestCost = cost; bestAxis = axis; bestSplit = split;
          }
        }
      }

      if (bestAxis === -1 || indices.length <= 2) {
        return { min, max, indices };
      }

      let leftIndices = [], rightIndices = [];
      for (const idx of indices) {
        if (triCentroids[idx][bestAxis] < bestSplit) leftIndices.push(idx); else rightIndices.push(idx);
      }

      return {
        min, max,
        left: subdivide(leftIndices),
        right: subdivide(rightIndices)
      };
    };

    const bvhRoot = subdivide(triIndices);
    this.nodes = [];
    this.flatTriangles = [];

    const flatten = (node,parent) => {
      const index = this.nodes.length;
      const flatNode = { min: node.min, max: node.max, num_triangles: 0, next: 0, parent: parent };
      this.nodes.push(flatNode);

      if (node.indices) {
        flatNode.num_triangles = node.indices.length;
        flatNode.next = this.flatTriangles.length; // tri_start
        for (const idx of node.indices) {
          this.flatTriangles.push(this.triangles[idx]);
        }
      } else {
        flatten(node.left,index);
        flatNode.next = flatten(node.right,index); // index of right child
      }
      return index;
    };

    flatten(bvhRoot,-1);
  }

  renormalize(bottomAlign = false) {
    let min = [Infinity, Infinity, Infinity], max = [-Infinity, -Infinity, -Infinity];
    for (let i = 0; i < this.vertex_positions.length; i += 3) {
      for (let k = 0; k < 3; k++) {
        min[k] = Math.min(min[k], this.vertex_positions[i + k]);
        max[k] = Math.max(max[k], this.vertex_positions[i + k]);
      }
    }
    const center = [(min[0] + max[0]) / 2, (min[1] + max[1]) / 2, (min[2] + max[2]) / 2];
    if (bottomAlign) center[1] = min[1];
    const size = Math.max(max[0] - min[0], max[1] - min[1], max[2] - min[2]) || 1;
    const scale = 2.0 / size;

    const m = mat4.create();
    mat4.scale(m, m, [scale, scale, scale]);
    mat4.translate(m, m, [-center[0], -center[1], -center[2]]);
    
    return this.bakeTransform(m);
  }

  /**
   * Generates spherical UV coordinates based on vertex positions.
   */
  calculateSphericalUVs() {
    const vCount = this.vertex_positions.length / 3;
    this.vertex_texcoords = new Float32Array(vCount * 2);
    this.index_texcoords = new Uint32Array(this.index_positions);

    for (let i = 0; i < vCount; i++) {
      const x = this.vertex_positions[i*3];
      const y = this.vertex_positions[i*3+1];
      const z = this.vertex_positions[i*3+2];
      const r = Math.sqrt(x*x + y*y + z*z) || 1.0;
      
      this.vertex_texcoords[i*2] = Math.atan2(z, x) / (2 * Math.PI) + 0.5;
      this.vertex_texcoords[i*2+1] = Math.asin(y / r) / Math.PI + 0.5;
    }
  }

  calculateFaceNormals() {
    const triCount = this.index_positions.length / 3;
    const newNormals = new Float32Array(this.index_positions.length * 3);
    
    const v0 = vec3.create(), v1 = vec3.create(), v2 = vec3.create();
    const edge1 = vec3.create(), edge2 = vec3.create(), normal = vec3.create();

    for (let i = 0; i < triCount; i++) {
      const i3 = i * 3;
      const p0 = this.index_positions[i3] * 3;
      const p1 = this.index_positions[i3 + 1] * 3;
      const p2 = this.index_positions[i3 + 2] * 3;

      vec3.set(v0, this.vertex_positions[p0], this.vertex_positions[p0+1], this.vertex_positions[p0+2]);
      vec3.set(v1, this.vertex_positions[p1], this.vertex_positions[p1+1], this.vertex_positions[p1+2]);
      vec3.set(v2, this.vertex_positions[p2], this.vertex_positions[p2+1], this.vertex_positions[p2+2]);

      vec3.sub(edge1, v1, v0);
      vec3.sub(edge2, v2, v0);
      vec3.cross(normal, edge1, edge2);
      vec3.normalize(normal, normal);

      // Assign the same normal to all 3 vertices of the face
      for(let j = 0; j < 3; j++) {
        newNormals[(i3 + j) * 3]     = normal[0];
        newNormals[(i3 + j) * 3 + 1] = normal[1];
        newNormals[(i3 + j) * 3 + 2] = normal[2];
      }
    }

    this.vertex_normals = newNormals;
    // Update indices to be 1:1 with the new normal buffer
    this.index_normals = new Uint32Array(this.index_positions.length);
    for(let i = 0; i < this.index_normals.length; i++) this.index_normals[i] = i;
    
    return this;
  }

  /**
   * Calculates smooth normals by averaging face normals at each vertex.
   */
  calculateSmoothNormals() {
    const vCount = this.vertex_positions.length / 3;
    const triCount = this.index_positions.length / 3;
    const smoothNormals = new Float32Array(vCount * 3);

    const v0 = vec3.create(), v1 = vec3.create(), v2 = vec3.create();
    const edge1 = vec3.create(), edge2 = vec3.create(), faceNormal = vec3.create();

    // Accumulate face normals into vertices
    for (let i = 0; i < triCount; i++) {
      const i3 = i * 3;
      const idxs = [this.index_positions[i3], this.index_positions[i3+1], this.index_positions[i3+2]];

      vec3.set(v0, this.vertex_positions[idxs[0]*3], this.vertex_positions[idxs[0]*3+1], this.vertex_positions[idxs[0]*3+2]);
      vec3.set(v1, this.vertex_positions[idxs[1]*3], this.vertex_positions[idxs[1]*3+1], this.vertex_positions[idxs[1]*3+2]);
      vec3.set(v2, this.vertex_positions[idxs[2]*3], this.vertex_positions[idxs[2]*3+1], this.vertex_positions[idxs[2]*3+2]);

      vec3.sub(edge1, v1, v0);
      vec3.sub(edge2, v2, v0);
      vec3.cross(faceNormal, edge1, edge2);
      // Note: We don't normalize here so that larger triangles contribute more (area-weighting)

      for (let j = 0; j < 3; j++) {
        smoothNormals[idxs[j]*3]     += faceNormal[0];
        smoothNormals[idxs[j]*3 + 1] += faceNormal[1];
        smoothNormals[idxs[j]*3 + 2] += faceNormal[2];
      }
    }

    // Final pass: Normalize all accumulated vectors
    const n = vec3.create();
    for (let i = 0; i < vCount; i++) {
      vec3.set(n, smoothNormals[i*3], smoothNormals[i*3+1], smoothNormals[i*3+2]);
      if (vec3.length(n) > 0) {
        vec3.normalize(n, n);
        smoothNormals[i*3]   = n[0];
        smoothNormals[i*3+1] = n[1];
        smoothNormals[i*3+2] = n[2];
      }
    }

    this.vertex_normals = smoothNormals;
    this.index_normals = new Uint32Array(this.index_positions);
    return this;
  }

  /**
   * Bakes a mat4 transformation into the vertex positions and normals.
   */
  
  bakeTransform(matrix) {
    const vCount = this.vertex_positions.length / 3;
    const nCount = this.vertex_normals.length / 3;

    // 1. Transform Positions (w = 1)
    const posVec = vec4.create();
    for (let i = 0; i < vCount; i++) {
      const i3 = i * 3;
      vec4.set(posVec, 
        this.vertex_positions[i3], 
        this.vertex_positions[i3 + 1], 
        this.vertex_positions[i3 + 2], 
        1.0
      );
      vec4.transformMat4(posVec, posVec, matrix);
      
      this.vertex_positions[i3]     = posVec[0];
      this.vertex_positions[i3 + 1] = posVec[1];
      this.vertex_positions[i3 + 2] = posVec[2];
    }

    // 2. Transform Normals (w = 0, using Inverse Transpose)
    if (nCount > 0) {
      const normalMatrix = mat4.create();
      mat4.invert(normalMatrix, matrix);
      mat4.transpose(normalMatrix, normalMatrix);

      const normVec = vec4.create();
      for (let i = 0; i < nCount; i++) {
        const i3 = i * 3;
        vec4.set(normVec, 
          this.vertex_normals[i3], 
          this.vertex_normals[i3 + 1], 
          this.vertex_normals[i3 + 2], 
          0.0
        );
        vec4.transformMat4(normVec, normVec, normalMatrix);
        
        // After transformation, normals must be re-normalized 
        // to account for scaling in the matrix
        let len = Math.sqrt(normVec[0]**2 + normVec[1]**2 + normVec[2]**2);
        if (len > 0) {
          this.vertex_normals[i3]     = normVec[0] / len;
          this.vertex_normals[i3 + 1] = normVec[1] / len;
          this.vertex_normals[i3 + 2] = normVec[2] / len;
        }
      }
    }

    // Mark for BVH rebuild if necessary
    //this.bvhreset = true; 
    return this;
  }

  generateMesh() {
    if (this.glData) return this.glData;
    const triCount = this.index_positions.length / 3;
    const vertexCount = triCount * 3;

    const p = new Float32Array(vertexCount * 3);
    const n = new Float32Array(vertexCount * 3);
    const u = new Float32Array(vertexCount * 2);
    const i = new Uint32Array(vertexCount);

    for (let idx = 0; idx < vertexCount; idx++) {
      const pi = this.index_positions[idx];
      const ni = this.index_normals[idx];
      const ui = this.index_texcoords[idx];

      // Copy Positions
      p[idx * 3]     = this.vertex_positions[pi * 3];
      p[idx * 3 + 1] = this.vertex_positions[pi * 3 + 1];
      p[idx * 3 + 2] = this.vertex_positions[pi * 3 + 2];

      // Copy Normals
      if (this.vertex_normals.length > ni * 3) {
        n[idx * 3]     = this.vertex_normals[ni * 3];
        n[idx * 3 + 1] = this.vertex_normals[ni * 3 + 1];
        n[idx * 3 + 2] = this.vertex_normals[ni * 3 + 2];
      }

      // Copy UVs
      if (this.vertex_texcoords.length > ui * 2) {
        u[idx * 2]     = this.vertex_texcoords[ui * 2];
        u[idx * 2 + 1] = this.vertex_texcoords[ui * 2 + 1];
      }

      i[idx] = idx;
    }

    this.glData = { p, n, u, i };
    return this.glData;
  }
}

class Model extends Primitive {
  constructor(name, material, model, inSceneBVH = true) {
    super(name,material,"Model");
    this.icon = "📐";
    this.model = model;
    this.inSceneBVH = inSceneBVH;
  }
  generateMesh() {
    return this.model.generateMesh();
  }
  // getBounds() {
  //   // Meshes already have a local BVH. We take the root node's AABB.
  //   const root = this.model.nodes[0];
  //   const worldMatrix = mat4.create();
  //   mat4.invert(worldMatrix, this.invMatrix);
  //   return transformAABB(root.min, root.max, worldMatrix);
  // }
  getBounds() {
    const worldMatrix = mat4.create();
    mat4.invert(worldMatrix, this.invMatrix);

    const positions = this.model.vertex_positions;
    const vertexCount = positions.length / 3;
    const threshold = 5000;

    if (vertexCount > 0 && vertexCount < threshold) {
      // --- PRECISE METHOD: Transform every unique vertex ---
      const min = vec3.fromValues(Infinity, Infinity, Infinity);
      const max = vec3.fromValues(-Infinity, -Infinity, -Infinity);
      const tempV = vec3.create();

      for (let i = 0; i < vertexCount; i++) {
        const i3 = i * 3;
        // Load local vertex position
        vec3.set(tempV, positions[i3], positions[i3 + 1], positions[i3 + 2]);
        
        // Transform to world space
        vec3.transformMat4(tempV, tempV, worldMatrix);
        
        // Expand AABB
        vec3.min(min, min, tempV);
        vec3.max(max, max, tempV);
      }
      return { min, max };
    } else {
      // --- FAST METHOD: Transform 8 corners of the local BVH root AABB ---
      const root = this.model.nodes[0];
      if (!root) {
        // Fallback if model is empty
        return { 
          min: vec3.fromValues(-1, -1, -1), 
          max: vec3.fromValues(1, 1, 1) 
        };
      }
      
      // Helper function assumed to be available in your environment
      // It takes local min/max and transforms the 8 corners by the matrix
      return transformAABB(root.min, root.max, worldMatrix);
    }
  }
}
Model.getSchema = function(mesh) {
  if (!mesh) mesh = { material: { _index:-1 }, model: { _node_offset: 0, _tri_offset: 0 } };
  return [
    { type: "mat4x4f", data: mesh.invMatrix },
    { type: "i32", data: mesh.material._index },
    { type: "i32", data: mesh.lightIdx },
    { type: "i32", data: 0 },
    { type: "u32", data: mesh.model._node_offset },
    { type: "vec3f", data: mesh.position },
    { type: "u32", data: mesh.model._tri_offset },
  ];
}

class Camera {
  constructor(canvas) {
    this.type = "Camera";
    this.name = "Camera";
    this.id = "camera";
    this.position = vec3.fromValues(0, 1.5, 4.5);
    this.target = vec3.fromValues(0, 0.5, 0);
    this.fov = 45;
    this.aperture = 0;
    this.focusDist = 1;
    this.exposure = 1;
    this.aspect = canvas.width / canvas.height;
    this.ray00 = vec3.create(); this.ray10 = vec3.create();
    this.ray01 = vec3.create(); this.ray11 = vec3.create();
    this.updateRays();
    this.jitteredPosition = vec3.fromValues([0,0,0]);
  }
  updateRays() {
    // const f = vec3.normalize(vec3.create(), vec3.sub(vec3.create(), this.target, this.position));
    // const r = vec3.normalize(vec3.create(), vec3.cross(vec3.create(), f, [0, 1, 0]));
    // const u = vec3.cross(vec3.create(), r, f);
    // const h = Math.tan((this.fov * Math.PI / 180) / 2); 
    // const w = h * this.aspect;
    // const hr = vec3.scale(vec3.create(), r, w); 
    // const hu = vec3.scale(vec3.create(), u, h);
    // vec3.sub(this.ray00, f, hr); vec3.sub(this.ray00, this.ray00, hu);
    // vec3.add(this.ray10, f, hr); vec3.sub(this.ray10, this.ray10, hu);
    // vec3.sub(this.ray01, f, hr); vec3.add(this.ray01, this.ray01, hu);
    // vec3.add(this.ray11, f, hr); vec3.add(this.ray11, this.ray11, hu);
  }
  updateRays2() {
    // 1. Setup Camera Basis
    const lookDir = vec3.sub(vec3.create(), this.target, this.position);
    const focusDist = vec3.length(lookDir) * this.focusDist;
    const f = vec3.normalize(vec3.create(), lookDir);
    const r = vec3.normalize(vec3.create(), vec3.cross(vec3.create(), f, [0, 1, 0]));
    const u = vec3.cross(vec3.create(), r, f);

    // 2. Determine View Plane size at Focus Distance
    // We calculate the plane dimensions specifically at the focusDist
    const h = Math.tan((this.fov * Math.PI / 180) / 2) * focusDist;
    const w = h * this.aspect;

    const hr = vec3.scale(vec3.create(), r, w);
    const hu = vec3.scale(vec3.create(), u, h);
    const focusCenter = vec3.scaleAndAdd(vec3.create(), this.position, f, focusDist);

    // 3. Define the 4 corners of the focus plane
    const p00 = vec3.create();
    const p10 = vec3.create();
    const p01 = vec3.create();
    const p11 = vec3.create();

    vec3.sub(p00, focusCenter, hr); vec3.sub(p00, p00, hu);
    vec3.add(p10, focusCenter, hr); vec3.sub(p10, p10, hu);
    vec3.sub(p01, focusCenter, hr); vec3.add(p01, p01, hu);
    vec3.add(p11, focusCenter, hr); vec3.add(p11, p11, hu);

    // 4. Generate Lens Jitter (Unit Disk Sampling)
    // We generate a random point inside a circle of radius 'aperture / 2'
    const angle = Math.random() * Math.PI * 2;
    const radius = Math.sqrt(Math.random()) * (this.aperture * 0.5);
    const offsetX = Math.cos(angle) * radius;
    const offsetY = Math.sin(angle) * radius;

    // Transform lens offset to world space basis (Right and Up vectors)
    const lensOffset = vec3.create();
    vec3.scaleAndAdd(lensOffset, lensOffset, r, offsetX);
    vec3.scaleAndAdd(lensOffset, lensOffset, u, offsetY);

    // Apply jitter to the camera position for this specific frame
    vec3.add(this.jitteredPosition, this.position, lensOffset);

    // 5. Calculate Rays
    // Rays now point from the jittered offset on the lens to the static focus plane
    vec3.sub(this.ray00, p00, this.jitteredPosition);
    vec3.sub(this.ray10, p10, this.jitteredPosition);
    vec3.sub(this.ray01, p01, this.jitteredPosition);
    vec3.sub(this.ray11, p11, this.jitteredPosition);
  }
  lookAt(x,y,z) {
    this.target = vec3.fromValues(x,y,z);
    this.updateRays();
  }
  setPosition(x,y,z) {
    this.position = vec3.fromValues(x,y,z);
    this.updateRays();
  }
}

class SceneBVHBuilder {
  constructor(objects) {
    this.objects = [];
    this.rebuild(objects);
  }

  // NEW: Quick rebuild method
  rebuild(newObjects = null) {
    if (newObjects) this.objects = newObjects;
    this.nodes = [];
    this.build();
  }

  build() {
    if (this.objects.length === 0) return;

    // Create an array of object references with their calculated world bounds
    const items = this.objects.map((obj, index) => ({
      index: index, // This is the index in the globalObjectBuffer
      aabb: obj.getBounds()
    }));

    this.recursiveBuild(items, 0);
  }

  recursiveBuild(items, depth) {
    const nodeIdx = this.nodes.length;
    
    // Initialize node with dummy data
    const node = {
      min: [0, 0, 0],
      max: [0, 0, 0],
      num_objects: 0,
      object_index: -1,
      next: -1
    };
    this.nodes.push(node);

    // Calculate Bounds for this node
    const bounds = this.calcBounds(items);
    node.min = bounds.min;
    node.max = bounds.max;

    // Leaf Node: Only 1 object left or max depth reached
    if (items.length <= 1 || depth > 20) {
      node.num_objects = items.length;
      node.object_index = items[0].index; // The pointer to globalObjectBuffer
      return;
    }

    // Split logic: Find the widest axis
    const size = vec3.sub(vec3.create(), bounds.max, bounds.min);
    let axis = 0;
    if (size[1] > size[0]) axis = 1;
    if (size[2] > size[axis]) axis = 2;

    // Sort items by the center of their AABB on the chosen axis
    items.sort((a, b) => {
      const centerA = (a.aabb.min[axis] + a.aabb.max[axis]) * 0.5;
      const centerB = (b.aabb.min[axis] + b.aabb.max[axis]) * 0.5;
      return centerA - centerB;
    });

    const mid = Math.floor(items.length / 2);
    
    // Left child is always current_index + 1
    this.recursiveBuild(items.slice(0, mid), depth + 1);
    
    // Right child index needs to be stored in 'next'
    node.next = this.nodes.length;
    this.recursiveBuild(items.slice(mid), depth + 1);
  }

  calcBounds(items) {
    const min = vec3.fromValues(Infinity, Infinity, Infinity);
    const max = vec3.fromValues(-Infinity, -Infinity, -Infinity);
    for (const item of items) {
      vec3.min(min, min, item.aabb.min);
      vec3.max(max, max, item.aabb.max);
    }
    return { min, max };
  }

  flatten() {
    // Each node is 8 floats (32 bytes):
    // [min.x, min.y, min.z, num_objects]
    // [max.x, max.y, max.z, next_node_index/object_index]
    const data = new Float32Array(this.nodes.length * 8);
    const view = new DataView(data.buffer);

    for (let i = 0; i < this.nodes.length; i++) {
      const n = this.nodes[i];
      const base = i * 8;
      
      data[base + 0] = n.min[0];
      data[base + 1] = n.min[1];
      data[base + 2] = n.min[2];
      // num_objects is stored as a bitcast uint32 in the 4th float slot
      view.setUint32((base + 3) * 4, n.num_objects, true);

      data[base + 4] = n.max[0];
      data[base + 5] = n.max[1];
      data[base + 6] = n.max[2];
      
      // If leaf, store object index. If branch, store index of right child.
      const ptr = (n.num_objects > 0) ? n.object_index : n.next;
      view.setUint32((base + 7) * 4, ptr, true);
    }
    return data;
  }
}

class Scene {
  constructor(canvas) {
    this.objects = [];
    this.camera = new Camera(canvas);
    this.bounces = 8;
    this.background = null;
  }
  newSphere() { var o = new Sphere(...arguments); this.objects.push(o); return o; }
  newCube() { var o = new Cube(...arguments); this.objects.push(o); return o; }
  newPlane() { var o = new Plane(...arguments); this.objects.push(o); return o; }
  newCylinder() { var o = new Cylinder(...arguments); this.objects.push(o); return o; }
  newTorus() { var o = new Torus(...arguments); this.objects.push(o); return o; }
  newModel() { var o = new Model(...arguments); this.objects.push(o); return o; }
  getMaterials() {
    var list = this.objects;
    var mats = [];
    for (var i = 0; i < list.length; i++) {
      var m = list[i].material || list[i];
      if (m && !mats.includes(m)) mats.push(m);
    }
    return mats;
  }
  getTextures() {
    var mats = this.getMaterials();
    var texs = [];
    for (var i = 0; i < mats.length; i++) {
      ['emissiveTex', 'albedoTex', 'normalTex', 'heightTex', 'roughnessTex', 'metallicTex'].forEach(t => {
        t = mats[i][t];
        if (t && !texs.includes(t)) texs.push(t);
      });
    }
    return texs;
  }
  lightPower(obj) {
    const MIN_LIGHT_POWER = 0.01; // Tweak this based on scene scale

    const mat = obj.material;
    if (obj.type != "Sphere" && obj.type != "Cube") return { power: 0 };
    if (mat.emissiveTex) return { power: 0 };

    // 1. Calculate Perceived Brightness (Luminance)
    const luminance = (0.2126 * mat.emittance[0] + 0.7152 * mat.emittance[1] + 0.0722 * mat.emittance[2]) * mat.emissionIntensity;

    if (luminance <= 0) return { power: 0 };
    const area = obj.getArea(); 
    const power = luminance * area;
    
    if (power < MIN_LIGHT_POWER) return { power: 0 };
    return { power, area };
  }
  getLights(objects) {
    let explicitLights = [];
    for (let i = 0; i < objects.length; i++) {
      const obj = objects[i];
      if (!obj.enableNEE) continue;
      const { power, area } = this.lightPower(obj);
      if (power <= 0) continue;
      obj.lightIdx = explicitLights.length;
      explicitLights.push(new Light(obj, i, area, power));
    }
    return explicitLights;
  }
}

class Light {
  constructor(object,index,area,power) {
    this.obj = object;
    this.objIdx = index;
    this.area = area;
    this.power = power;
    //
    this.scale = 1;
    if (object.type == "Sphere") {
      var avgScale = object.scale.reduce((a,v)=>a+v,0)/3;
      object.scaleSet(avgScale,avgScale,avgScale);
      this.scale = avgScale;
    } else if (object.type == "Cube") {
      this.scale = Math.hypot(...object.scale);
    }
  }
}
Light.getSchema = function(light) {
  if (!light) light = { objIdx: -1, obj: {} };
  return [
    { type: "i32", data: light.objIdx },
    { type: "f32", data: light.area },
    { type: "f32", data: light.power },
    { type: "f32", data: light.scale },
    { type: "mat4x4f", data: light.obj.matrix },
  ];
};

async function loadText(url) {
  var res = await fetch(url,{});
  return await res.text();
}

// --- RENDERER ---
class Renderer {
  constructor(canvas) {
    if (!navigator.gpu) return alert("WebGPU not supported.");
    this.canvas = canvas;
    this.context = canvas.getContext("webgpu");
    if (!this.context) return alert("WebGPU not supported.");
    this.scene = null;
    this.sceneBvh = new SceneBVHBuilder();
    this.frame = 0;
    this.currentFlags = {};
    this.section = { x: 0, y: 0, width: 16, height: 16 };
    this.scale = { width: 16, height: 16 };
  }
  
  async init() {
    const { context } = this;
    const adapter = await navigator.gpu.requestAdapter();
    const limits = this.limits = adapter.limits;
    console.log(`Your GPU supports up to ${limits.maxStorageBuffersPerShaderStage} storage buffers.`);
    console.log(`Your GPU supports up to ${limits.maxStorageBufferBindingSize} binding size.`);
    var required = [
      'maxBufferSize',
      'maxStorageBuffersPerShaderStage',
      'maxComputeWorkgroupStorageSize',
      'maxDynamicStorageBuffersPerPipelineLayout',
      'maxDynamicUniformBuffersPerPipelineLayout',
      'maxInterStageShaderVariables',
      'maxSampledTexturesPerShaderStage',
      'maxSamplersPerShaderStage',
      'maxStorageBufferBindingSize',
      'maxStorageBuffersPerShaderStage',
      'maxStorageTexturesPerShaderStage',
      'maxTextureArrayLayers',
      'maxTextureDimension1D',
      'maxTextureDimension2D',
      'maxTextureDimension3D',
      'maxUniformBufferBindingSize',
      'maxUniformBuffersPerShaderStage',
      'maxVertexAttributes'
    ];
    var requiredLimits = {};
    for (var i of required) requiredLimits[i] = limits[i];
    this.device = await adapter.requestDevice({
      requiredLimits // get the best
    });
    context.configure({ 
      device: this.device, 
      format: 'rgba8unorm', 
      usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.STORAGE_BINDING | GPUTextureUsage.COPY_DST,
      alphaMode: 'premultiplied', 
    });
  }

  packDataFromSchema(objects, getSchema) {
    // 1. Get a sample schema to calculate stride
    // We use a prototype instance if the array is empty
    const sampleObj = objects.length > 0 ? objects[0] : false;
    const schema = getSchema(sampleObj);

    let bytesPerObject = 0;
    const sizes = { vec2f: 8, vec3f: 12, vec4f: 16, f32: 4, i32: 4, u32: 4, mat2x2f: 16, mat3x3f: 36, mat4x4f: 64 };
    schema.forEach(item => {
      bytesPerObject += item.padding ? (item.spots || 1) * 4 : sizes[item.type];
    });

    // 2. Align to 16 bytes (WGSL Requirement)
    bytesPerObject = (bytesPerObject + 15) & ~15;
    const strideFloats = bytesPerObject / 4;

    // 3. Handle Empty Arrays: Create 1 dummy object if count is 0
    const count = Math.max(1, objects.length);
    const data = new Float32Array(count * strideFloats);
    const view = new DataView(data.buffer);

    // 4. If we actually have objects, fill them
    if (objects.length <= 0) return { data: data, size: bytesPerObject };
    objects.forEach((obj, objIdx) => {
      const baseByte = objIdx * bytesPerObject;
      let offset = 0;
      getSchema(obj).forEach(item => {
        const addr = baseByte + offset;
        if (!item.padding) {
          if (item.type === "vec2f" || item.type === "vec3f" || item.type == "vec4f" || item.type === "mat2x2f" || item.type === "mat3x3f" || item.type === "mat4x4f") {
            data.set(item.data, addr / 4);
          } else if (item.type === "f32") {
            view.setFloat32(addr, item.data, true);
          } else if (item.type === "i32") {
            view.setInt32(addr, item.data, true);
          } else if (item.type === "u32") {
            view.setUint32(addr, item.data, true);
          }
        }
        // Increment offset based on type
        offset += item.padding ? (item.spots || 1) * 4 : sizes[item.type];
      });
    });

    return { data: data, size: bytesPerObject };
  }

  packSceneData(includeStatic = true) {
    const scene = this.scene;
    
    // 1. Materials
    const mats = scene.getMaterials();
    let hasHeightMaps = false;
    mats.forEach((m, i) => { m._index = i; if (m.heightTex) hasHeightMaps = true; });
    const matPack = this.packDataFromSchema(mats, Material.getSchema);

    console.log("Packed materials");

    // 2. Filter Objects
    const modelObjects = scene.objects.filter(o => o.type === "Model");
    const primitives = scene.objects.filter(o => ["Sphere","Cube","Cylinder","Torus"].includes(o.type));
    const inBvhModels = modelObjects.filter(v => v.inSceneBVH);
    const listModels = modelObjects.filter(v => !v.inSceneBVH);
    const planes = scene.objects.filter(o => o.type === "Plane");
    const sceneObjects = primitives.concat(inBvhModels);

    const explicitLights = scene.getLights(sceneObjects); // This calls your new method
    const hasLights = explicitLights.length > 0;
    const lightPack = this.packDataFromSchema(explicitLights, Light.getSchema);
    this.totalLightPower = explicitLights.reduce((a,v)=>a+v.power,0);

    // 4. Static Model Data (BLAS + Triangles)
    var bvhData = new Float32Array(8), triData = new Float32Array(32);
    if (includeStatic) {
      const uniqueModels = [];
      modelObjects.forEach(obj => { if (!uniqueModels.includes(obj.model)) uniqueModels.push(obj.model); });

      let totalNodes = 0; let totalTriangles = 0;
      uniqueModels.forEach(m => { 
        m._node_offset = totalNodes; 
        m._tri_offset = totalTriangles; 
        totalNodes += m.nodes.length; 
        totalTriangles += m.flatTriangles.length; 
      });

      bvhData = new Float32Array(Math.max(1, totalNodes) * 8);
      const bvhView = new DataView(bvhData.buffer);
      triData = new Float32Array(Math.max(1, totalTriangles) * 32);

      uniqueModels.forEach(m => {
        m.nodes.forEach((node, nIdx) => {
          const nBase = (m._node_offset + nIdx) * 8;
          bvhData.set(node.min, nBase); bvhView.setUint32((nBase + 3) * 4, node.num_triangles, true);
          bvhData.set(node.max, nBase + 4); bvhView.setUint32((nBase + 7) * 4, node.next, true);
        });
        m.flatTriangles.forEach((tri, tIdx) => {
          const tBase = (m._tri_offset + tIdx) * 32;
          triData.set([...tri.v0, 0], tBase + 0); triData.set([...tri.v1, 0], tBase + 4); triData.set([...tri.v2, 0], tBase + 8);
          triData.set([...tri.n0, 0], tBase + 12); triData.set([...tri.n1, 0], tBase + 16); triData.set([...tri.n2, 0], tBase + 20);
          triData.set([...tri.u0, ...tri.u1, ...tri.u2], tBase + 24);
        });
      });
    }

    // 3. BVH & Dynamic Objects
    if (!this.sceneBvh) {
      this.sceneBvh = new SceneBVHBuilder(sceneObjects);
    } else {
      this.sceneBvh.rebuild(sceneObjects);
    }

    const objectPack = this.packDataFromSchema(this.sceneBvh.objects, (obj) => {
      if (!obj) obj = new Sphere({_index:-1},0,0,0,1);
      return obj.constructor.getSchema(obj);
    });
    
    const tlasData = this.sceneBvh.flatten();
    const planePack = this.packDataFromSchema(planes, Plane.getSchema);
    const meshPack = this.packDataFromSchema(listModels, Model.getSchema);

    const result = {
      mat: matPack,
      object: objectPack,
      tlas: { data: tlasData, size: tlasData.byteLength },
      plane: planePack,
      mesh: meshPack,
      bvh: { data: bvhData },
      triangle: { data: triData },
      light: lightPack,
      flags: {
        hasSpheres: primitives.some(o => o.type === "Sphere"),
        hasCubes: primitives.some(o => o.type === "Cube"),
        hasCylinders: primitives.some(o => o.type === "Cylinder"),
        hasTori: primitives.some(o => o.type === "Torus"),
        hasMeshes: inBvhModels.length > 0,
        hasListMeshes: listModels.length > 0,
        hasPlanes: planes.length > 0,
        hasHeightMaps: hasHeightMaps,
        hasLights: hasLights,
        hasSkybox: scene.background instanceof HDRTexture,
        misSkybox: !scene.background.plainColor
      }
    };

    return result;
  }

  async prepareTextureArray(scene) {
    const textures = scene.getTextures();
    const size = 512; // Choose your highest common resolution

    // 1. Create the 'Stack'
    const texArray = this.device.createTexture({
      size: [size, size, Math.max(1, textures.length)],
      format: 'rgba8unorm',
      dimension: '2d',
      usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST | GPUTextureUsage.RENDER_ATTACHMENT
    });

    for (let i = 0; i < textures.length; i++) {
      const img = textures[i].image;
      
      // Use createImageBitmap to resize on the fly (very efficient)
      const bitmap = await createImageBitmap(img, {
        resizeWidth: size,
        resizeHeight: size,
        resizeQuality: 'high'
      });

      // 2. Upload to specific 'Layer' (origin[2] = i)
      this.device.queue.copyExternalImageToTexture(
        { source: bitmap },
        { texture: texArray, origin: [0, 0, i] }, 
        [size, size]
      );
      
      // Save the index to your Material buffer logic
      textures[i].texIndex = i;
    }
    
    return texArray.createView({ dimension: '2d-array' });
  }

  async setScene(scene, isgbuf = false) {
    this.isgbuf = isgbuf;

    this.scene = scene;
    const { canvas, device } = this;

    console.log(this.device.limits.maxStorageBuffersPerShaderStage);

    // --- 0. PREPARE TEXTURES (Up to 8 Supported) ---
    const gpuTextureView = await this.prepareTextureArray(scene);
    const sampler = device.createSampler({
      magFilter: 'linear', minFilter: 'linear',
      addressModeU: 'repeat', addressModeV: 'repeat' // Required for POM tiling
    });

    // --- NEW: PREPARE HDRI SKYBOX ---
    let hdrTextureView;
    const skybox = scene.background; // Assuming you have this in your scene object
    const hasSkybox = skybox instanceof HDRTexture;
    if (hasSkybox) {
      await Promise.resolve(skybox.loaded);
      const skyTex = device.createTexture({ 
        size: [ skybox.width, skybox.height ],
        format: 'rgba16float', 
        usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST
      });

      device.queue.writeTexture(
        { texture: skyTex },
        skybox.data,
        { bytesPerRow: skybox.width * 8 },
        [ skybox.width, skybox.height ]
      );

      hdrTextureView = skyTex.createView();
    } else {
      // Fallback to a dark blue dummy sky if no URL provided
      const dummySky = device.createTexture({ size: [1, 1], format: 'rgba16float', usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST });
      device.queue.writeTexture({ texture: dummySky }, new Float16Array([0.02, 0.03, 0.05, 1.0]), { bytesPerRow: 8 }, [1, 1]);
      hdrTextureView = dummySky.createView();
      // const dummyTex = device.createTexture({ size: [1, 1], format: 'rgba8unorm', usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST });
      // device.queue.writeTexture({ texture: dummyTex }, new Uint8Array([255, 255, 255, 255]), { bytesPerRow: 4 }, [1, 1]);
      // hdrTextureView = dummyTex.createView();
    }
    const skySampler = device.createSampler({
      magFilter: 'linear',
      minFilter: 'linear',
    });

    const { skyCDF, sky_cdf_index, totalWeight } = skybox.buildHDRCDF();
    
    console.log("Created Textures");

    // Build the data packets
    this.sceneBvh = null; // Force fresh BVH builder for a new scene
    const sceneData = this.packSceneData(true);
    this.currentFlags = sceneData.flags; // Store flags for dynamic compilation checks

    console.log("Loaded Primitives");

    const makeBuf = (data, minSize = 16) => {
      const size = Math.max(minSize, data.byteLength);
      const b = this.device.createBuffer({ 
        size: size, 
        usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST 
      });
      if (data.byteLength > 0) this.device.queue.writeBuffer(b, 0, data);
      return b;
    };

    // --- 5. CREATE THE BUFFERS ---
    this.buffers = {
      mesh: makeBuf(sceneData.mesh.data, sceneData.mesh.size),
      bvh: makeBuf(sceneData.bvh.data, 32), 
      triangle: makeBuf(sceneData.triangle.data, 128),
      mat: makeBuf(sceneData.mat.data, sceneData.mat.size), 
      object: makeBuf(sceneData.object.data, sceneData.object.size), 
      tlas: makeBuf(sceneData.tlas.data, 32),         
      plane: makeBuf(sceneData.plane.data, sceneData.plane.size),
      light: makeBuf(sceneData.light.data, sceneData.light.size),
      skycdf: makeBuf(skyCDF,4),
    };

    this.uBuf = device.createBuffer({ size: 28 * 4, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
    
    console.log("Created Buffers");

    const wgslCode = await loadText('shader.wgsl');

    console.log("Code Loaded");

    const shaderModule = device.createShaderModule({ code: wgslCode });
    
    const info = await shaderModule.getCompilationInfo();
    if (info.messages.length > 0) {
      console.error("WGSL Compilation Failed:");
      for (const m of info.messages) {
        const line = m.lineNum;
        const col = m.linePos;
        console.warn(`Line ${line}:${col} - ${m.message}`);
      }
    }

    console.log("Code Compiled");

    const f = sceneData.flags;

    this.pipe = device.createComputePipeline({ 
      layout: 'auto', 
      compute: { 
        module: shaderModule, 
        entryPoint: isgbuf ? 'gbuf_main' :'main',
        constants: {
          0: scene.bounces,
          1: f.hasSpheres ? 1 : 0, 
          2: f.hasCubes ? 1 : 0, 
          3: f.hasPlanes ? 1 : 0, 
          4: f.hasCylinders ? 1 : 0, 
          5: f.hasTori ? 1 : 0, 
          6: f.hasMeshes ? 1 : 0, 
          7: f.hasListMeshes ? 1 : 0, 
          8: f.hasHeightMaps ? 1 : 0,
          9: f.hasLights ? 1 : 0,
          10: f.hasSkybox ? 1 : 0,
          11: f.misSkybox ? 1 : 0,
        }
      }
    });

    console.log("Pipeline Created");
    
    this.skyboxData = {
      total_lum: totalWeight,
      width: skybox.width,
      height: skybox.height,
      sky_cdf_index: sky_cdf_index,
    };
    this.gpuTextureView = gpuTextureView;
    this.sampler = sampler;
    this.hdrTextureView = hdrTextureView;
    this.skySampler = skySampler;
    this.resize();

    console.log("Bindings Created");

    this.reset();
    console.log("Scene loaded!");
  }

  createBindGroup() {
    this.bG = this.device.createBindGroup({
      layout: this.pipe.getBindGroupLayout(0),
      entries: [
        { binding: 0, resource: { buffer: this.uBuf } },
        { binding: 1, resource: { buffer: this.aBuf } },
        { binding: 2, resource: this.tex.createView() },
        { binding: 3, resource: { buffer: this.buffers.mat } },
        { binding: 4, resource: { buffer: this.buffers.object } },
        { binding: 5, resource: { buffer: this.buffers.tlas } },
        { binding: 6, resource: { buffer: this.buffers.mesh } },
        { binding: 7, resource: { buffer: this.buffers.bvh } },
        { binding: 8, resource: { buffer: this.buffers.triangle } },
        { binding: 9, resource: { buffer: this.buffers.plane } },
        { binding: 11, resource: this.gpuTextureView },
        { binding: 12, resource: this.sampler },
        { binding: 13, resource: this.hdrTextureView },
        { binding: 14, resource: this.skySampler },
      ].concat(this.isgbuf ? [
        { binding: 17, resource: { buffer: this.gBuf } }
      ] : [
        { binding: 10, resource: { buffer: this.buffers.light } },
        { binding: 15, resource: { buffer: this.buffers.skycdf } },
      ])
    });
    return this.bG;
  }

  async updateObjects() {
    if (!this.scene || !this.sceneBvh || !this.buffers) return;
    const { device, buffers } = this;

    // Fetch new dynamic data
    const sceneData = this.packSceneData(false);

    // 1. Check if Shader Re-compilation is required
    const flagsMatch = Object.keys(sceneData.flags).every(k => sceneData.flags[k] === this.currentFlags[k]);

    // 2. Verify GPU buffers can fit the new data
    const fitsBuffer = 
        sceneData.object.data.byteLength <= buffers.object.size && 
        sceneData.tlas.data.byteLength <= buffers.tlas.size &&
        sceneData.plane.data.byteLength <= buffers.plane.size &&
        sceneData.mesh.data.byteLength <= buffers.mesh.size &&
        sceneData.mat.data.byteLength <= buffers.mat.size;
    
    if (flagsMatch && fitsBuffer) {
      // FAST PATH: Upload modifications sequentially
      if (sceneData.object.data.byteLength > 0) device.queue.writeBuffer(buffers.object, 0, sceneData.object.data);
      if (sceneData.tlas.data.byteLength > 0) device.queue.writeBuffer(buffers.tlas, 0, sceneData.tlas.data);
      if (sceneData.plane.data.byteLength > 0) device.queue.writeBuffer(buffers.plane, 0, sceneData.plane.data);
      if (sceneData.mesh.data.byteLength > 0) device.queue.writeBuffer(buffers.mesh, 0, sceneData.mesh.data);
      if (sceneData.mat.data.byteLength > 0) device.queue.writeBuffer(buffers.mat, 0, sceneData.mat.data); // Upload materials instantly too!
      
      //this.clear(); // Clear accumulation instantly
    } else {
      // SLOW PATH: Buffer capacities exceeded or new primitive introduced
      console.warn("Buffer capacity or Pipeline constants changed. Executing full scene rebuild.");
      await this.setScene(this.scene);
    }
  }

  resize() {
    if (!this.device || !this.scene) return;

    var width = this.canvas.width;
    var height = this.canvas.height;

    // 3. Recreate the Storage Texture (The one the shader writes to)
    if (this.tex) this.tex.destroy();
    this.tex = this.device.createTexture({
      size: [width, height],
      format: 'rgba8unorm',
      usage: GPUTextureUsage.STORAGE_BINDING | GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_SRC | GPUTextureUsage.RENDER_ATTACHMENT
    });

    // 4. Recreate the Accumulation Buffer (The 16-byte-per-pixel float buffer)
    // This is where the raw light data is summed up (4 floats per pixel)
    if (this.aBuf) this.aBuf.destroy();
    this.aBuf = this.device.createBuffer({
      size: width * height * 16, 
      usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST
    });

    if (this.isgbuf) {
      if (this.gBuf) this.gBuf.destroy();
      this.gBuf = this.device.createBuffer({
        size: width * height * 4 * 12,
        usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST
      });
    }

    // 5. Update the Bind Group
    // Since the texture view and buffer reference changed, we must rebuild the Bind Group
    // We reuse the existing pipeline layout.
    this.createBindGroup();

    // 6. Reset the frame counter so accumulation starts over
    this.reset();
    
    console.log(`Resized to ${width}x${height}`);
  }

  updateUniforms() {
    const { canvas, device, uBuf } = this;

    const cam = this.scene.camera;
    cam.updateRays2();
    var randomSeed = Math.floor(Math.random() * 0xFFFFFFFF);
    const uData = new Float32Array(28);
    const uView = new DataView(uData.buffer);

    uData.set(cam.jitteredPosition, 0);
    uView.setUint32(3*4, this.frame, true);

    uData.set(cam.ray00, 4); 
    uView.setUint32(7*4, this.size.width, true);

    uData.set(cam.ray10, 8);
    uView.setUint32(11*4, this.size.height, true);

    uData.set(cam.ray01, 12); 
    uView.setFloat32(15*4, cam.exposure, true);

    uData.set(cam.ray11, 16);
    uView.setUint32(19*4, randomSeed, true);

    uView.setUint32(20*4, this.skyboxData.width, true);
    uView.setUint32(21*4, this.skyboxData.height, true);
    uView.setFloat32(22*4, this.skyboxData.total_lum, true);
    uView.setFloat32(23*4, this.totalLightPower, true);
    uView.setUint32(24*4, this.section.x, true);
    uView.setUint32(25*4, this.section.y, true);
    uView.setUint32(26*4, this.skyboxData.sky_cdf_index, true);

    device.queue.writeBuffer(uBuf, 0, uData);
  }

  async render(tsize=256,reps=1,tilesVisible=false) {
    if (!this.scene) return;
    const { canvas, context, device, tex } = this;

    var enc = device.createCommandEncoder();

    const startingFrame = this.frame;
    const FRAME_REPS = reps;//this.frame < 16 ? 1 : 16;

    const TILE_SIZE = tsize;
    const tilesX = Math.ceil(canvas.width / TILE_SIZE);
    const tilesY = Math.ceil(canvas.height / TILE_SIZE);

    this.size = { width: canvas.width, height: canvas.height };

    for (let y = 0; y < tilesY; y++) {
      for (let x = 0; x < tilesX; x++) {
        // 1. Calculate the actual pixel bounds for this tile
        const left = x * TILE_SIZE;
        const top = y * TILE_SIZE;
        // Handle the "remainder" pixels at the edges of the canvas
        const width = Math.min(TILE_SIZE, canvas.width - left);
        const height = Math.min(TILE_SIZE, canvas.height - top);
        
        this.section = { 
          x: left, 
          y: top, 
          width: width, 
          height: height 
        };

        for (var i = 0; i < FRAME_REPS; i++) {
          this.frame = startingFrame + i;
          this.renderSection(enc);
        }

        if (tilesVisible) enc.copyTextureToTexture({ texture: tex }, { texture: context.getCurrentTexture() }, [canvas.width, canvas.height]);

        device.queue.submit([enc.finish()]);
        await device.queue.onSubmittedWorkDone();
        enc = device.createCommandEncoder();
      }
    }

    // if (this.frame < 10 
    //   || (this.frame < 100 && this.frame % 5 == 0)
    //   || (this.frame < 1000 && this.frame % 25 == 0)
    //   || (this.frame % 125 == 0)) 
      enc.copyTextureToTexture({ texture: tex }, { texture: context.getCurrentTexture() }, [canvas.width, canvas.height]);

    device.queue.submit([enc.finish()]);

    await device.queue.onSubmittedWorkDone();
    
    this.frame = startingFrame + FRAME_REPS;
  }
  
  renderSection(enc) {
    const { bG, pipe } = this;
    
    this.updateUniforms();
    
    const pass = enc.beginComputePass();
    pass.setPipeline(pipe);
    pass.setBindGroup(0, bG);
    pass.dispatchWorkgroups(Math.ceil(this.section.width / 16), Math.ceil(this.section.height / 16));
    pass.end();
  }

  async initPreview(targetTime) {
    const { device } = this;

    this.targetFrameTime = targetTime || 1000 / 60; // 16.6ms for 60 FPS
    this.currentPreviewSize = 128;    // Start size
    this.lastFrameTime = performance.now();
    
    const scaleShader = await loadText('scale.wgsl');

    this.blitScaleBuf = device.createBuffer({
      size: 8,
      usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST
    });

    this.blitPipe = device.createComputePipeline({
      layout: 'auto',
      compute: {
        module: device.createShaderModule({ code: scaleShader }),
        entryPoint: 'main'
      }
    });
  }

  async renderPreview() {
    const { device, canvas, context, tex } = this;
    
    if (this.frame < 16) {
      // 1. MEASURE PERFORMANCE
      const now = performance.now();
      const frameTime = now - this.lastFrameTime;
      this.lastFrameTime = now;

      // 2. ADJUST SIZE (Adaptive Logic)
      var newPrev = this.currentPreviewSize;
      const perfRatio = this.targetFrameTime / frameTime;
      const adjustment = (perfRatio - 1.0) * 20;
      newPrev += adjustment;
      const maxPossible = Math.max(canvas.width, canvas.height);
      newPrev = Math.min(maxPossible, Math.max(64, newPrev));
      if (Math.abs(this.currentPreviewSize - newPrev) > 4) {
        this.currentPreviewSize = newPrev;
        this.frame = 0; 
      }
    }

    const maxsize = Math.floor(this.currentPreviewSize);
    const scale = Math.min(maxsize / canvas.width, maxsize / canvas.height);
    const pWidth = Math.floor(canvas.width * scale);
    const pHeight = Math.floor(canvas.height * scale);

    // ... Rest of your render logic exactly as before using pWidth/pHeight ...
    this.size = { width: pWidth, height: pHeight };
    this.section = { x: 0, y: 0, width: pWidth, height: pHeight };
    
    const ratio = new Float32Array([pWidth / canvas.width, pHeight / canvas.height]);
    device.queue.writeBuffer(this.blitScaleBuf, 0, ratio);

    let enc = device.createCommandEncoder();
    this.renderSection(enc);
    device.queue.submit([enc.finish()]);

    enc = device.createCommandEncoder();
    const pass = enc.beginComputePass();
    const scaleBG = device.createBindGroup({
      layout: this.blitPipe.getBindGroupLayout(0),
      entries: [
        { binding: 0, resource: tex.createView() },
        { binding: 1, resource: context.getCurrentTexture().createView() },
        { binding: 2, resource: { buffer: this.blitScaleBuf } }
      ]
    });

    pass.setPipeline(this.blitPipe);
    pass.setBindGroup(0, scaleBG);
    pass.dispatchWorkgroups(Math.ceil(canvas.width / 16), Math.ceil(canvas.height / 16));
    pass.end();

    device.queue.submit([enc.finish()]);
    await device.queue.onSubmittedWorkDone();

    this.frame++;
  }

  reset() {
    this.frame = 0;
  }

  clear() {
    this.reset();
    const { canvas, context, device} = this;
    const canvasTexture = context.getCurrentTexture();
    const renderPassDescriptor = {
      colorAttachments: [{
        view: canvasTexture.createView(),
        clearValue: { r: 0.0, g: 0.0, b: 0.0, a: 0.0 }, // The clear color (transparent in this case)
        loadOp: 'clear',
        storeOp: 'store',
      }],
    };
    const encoder = device.createCommandEncoder({ label: 'clear encoder' });
    const pass = encoder.beginRenderPass(renderPassDescriptor);
    pass.end();

    device.queue.submit([encoder.finish()]);
    console.log("Cleared!");
  }
}
class Denoiser {
  constructor(renderer) {
    this.r = renderer; 
    this.device = renderer.device;
    
    // Default optimized parameters from our previous testing
    this.passes = 4;
    this.sigmaColor = 0.30;
    this.sigmaNormal = 128.0;
    this.sigmaDepth = 0.2;
    this.sigmaAlbedo = 0.07;
    this.sigmaMaterial = 0.07;
    this.glossyProtect = 0.75;
    this.exposure = renderer.scene.camera.exposure;
    
    // Feature flags
    this.useMedian = true;
    this.useDemodulate = true;

    this.bufA = null;
    this.bufB = null;
    this.uBuf = null;
    
    // 48 bytes (12 * 4 bytes) for uniform parameters
    this.uBufData = new ArrayBuffer(48); 
    
    this.prepassPipe = null;
    this.atrousPipe = null;
    this.compositePipe = null;
  }

  async init() {
    // Single monolithic shader containing all 3 passes to easily share structs
    const denoiserWgsl = await loadText('denoiser.wgsl');

    this.module = this.device.createShaderModule({ code: denoiserWgsl });
    
    // Check for compilation errors
    const info = await this.module.getCompilationInfo();
    if (info.messages.length > 0) {
      console.error("Denoiser WGSL Compilation Messages:");
      for (const m of info.messages) {
        console.warn(`Line ${m.lineNum}:${m.linePos} - ${m.message}`);
      }
    }

    this.prepassPipe = this.device.createComputePipeline({
      layout: 'auto', compute: { module: this.module, entryPoint: 'prepass_main' }
    });

    this.atrousPipe = this.device.createComputePipeline({
      layout: 'auto', compute: { module: this.module, entryPoint: 'atrous_main' }
    });

    this.compositePipe = this.device.createComputePipeline({
      layout: 'auto', compute: { module: this.module, entryPoint: 'composite_main' }
    });

    this.uBuf = this.device.createBuffer({
      size: 48, 
      usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST
    });
  }

  setupBuffers() {
    const { device, r } = this;
    const width = r.canvas.width;
    const height = r.canvas.height;
    const pixelCount = width * height;

    if (this.bufA) this.bufA.destroy();
    this.bufA = device.createBuffer({
      size: pixelCount * 16,
      usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_SRC | GPUBufferUsage.COPY_DST
    });

    if (this.bufB) this.bufB.destroy();
    this.bufB = device.createBuffer({
      size: pixelCount * 16,
      usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_SRC | GPUBufferUsage.COPY_DST
    });

    // -----------------------------------------------------
    // Create explicitly targeted Bind Groups for each pass
    // -----------------------------------------------------
    
    // Prepass: Reads Renderer's Accumulation Buffer -> Writes BufA
    this.bgPrepass = device.createBindGroup({
      layout: this.prepassPipe.getBindGroupLayout(0),
      entries: [
        { binding: 0, resource: { buffer: this.uBuf } },
        { binding: 1, resource: { buffer: r.aBuf } },
        { binding: 2, resource: { buffer: r.gBuf } },
        { binding: 3, resource: { buffer: this.bufA } }
      ]
    });

    // Atrous Ping-Pong A: Reads BufA -> Writes BufB
    this.bgAtrousA = device.createBindGroup({
      layout: this.atrousPipe.getBindGroupLayout(0),
      entries: [
        { binding: 0, resource: { buffer: this.uBuf } },
        { binding: 1, resource: { buffer: this.bufA } },
        { binding: 2, resource: { buffer: r.gBuf } },
        { binding: 3, resource: { buffer: this.bufB } }
      ]
    });

    // Atrous Ping-Pong B: Reads BufB -> Writes BufA
    this.bgAtrousB = device.createBindGroup({
      layout: this.atrousPipe.getBindGroupLayout(0),
      entries: [
        { binding: 0, resource: { buffer: this.uBuf } },
        { binding: 1, resource: { buffer: this.bufB } },
        { binding: 2, resource: { buffer: r.gBuf } },
        { binding: 3, resource: { buffer: this.bufA } }
      ]
    });

    // Composite A/B: Reads final Buf (A or B) -> Writes final Canvas Texture
    const outView = r.tex.createView();
    this.bgCompositeA = device.createBindGroup({
      layout: this.compositePipe.getBindGroupLayout(0),
      entries: [
        { binding: 0, resource: { buffer: this.uBuf } },
        { binding: 1, resource: { buffer: this.bufA } },
        { binding: 2, resource: { buffer: r.gBuf } },
        { binding: 4, resource: outView }
      ]
    });

    this.bgCompositeB = device.createBindGroup({
      layout: this.compositePipe.getBindGroupLayout(0),
      entries: [
        { binding: 0, resource: { buffer: this.uBuf } },
        { binding: 1, resource: { buffer: this.bufB } },
        { binding: 2, resource: { buffer: r.gBuf } },
        { binding: 4, resource: outView }
      ]
    });
  }

  updateUniforms() {
    const f32 = new Float32Array(this.uBufData);
    const u32 = new Uint32Array(this.uBufData);
    
    u32[0] = this.r.canvas.width;
    u32[1] = this.r.canvas.height;
    u32[2] = 1; // Default step_width
    u32[3] = this.passes;
    
    f32[4] = this.sigmaColor;
    f32[5] = this.sigmaNormal;
    f32[6] = this.sigmaDepth;
    f32[7] = this.sigmaAlbedo;
    f32[8] = this.sigmaMaterial;
    f32[9] = this.glossyProtect;
    f32[10] = this.exposure;
    
    // Combine feature flags
    u32[11] = (this.useMedian ? 1 : 0) | (this.useDemodulate ? 2 : 0);
    
    this.device.queue.writeBuffer(this.uBuf, 0, this.uBufData);
  }

  execute() {
    if (!this.prepassPipe || !this.r.aBuf) return;
    const { device, r } = this;
    
    this.updateUniforms();

    const wX = Math.ceil(r.canvas.width / 16);
    const wY = Math.ceil(r.canvas.height / 16);
    const encoder = device.createCommandEncoder();
    
    // -----------------------------------------------------
    // 1. PREPASS (Median & Demodulate)
    // -----------------------------------------------------
    const prepass = encoder.beginComputePass();
    prepass.setPipeline(this.prepassPipe);
    prepass.setBindGroup(0, this.bgPrepass);
    prepass.dispatchWorkgroups(wX, wY);
    prepass.end();

    // -----------------------------------------------------
    // 2. À-TROUS WAVELET PASSES
    // -----------------------------------------------------
    for (let i = 0; i < this.passes; i++) {
      const stepSize = 1 << i; // 1, 2, 4, 8, 16...
      
      // Update just the step_width in the uniform buffer (offset 8 bytes)
      device.queue.writeBuffer(this.uBuf, 8, new Uint32Array([stepSize]));

      const pass = encoder.beginComputePass();
      pass.setPipeline(this.atrousPipe);
      // If i is even: read BufA, write BufB. If odd: read BufB, write BufA.
      pass.setBindGroup(0, i % 2 === 0 ? this.bgAtrousA : this.bgAtrousB);
      pass.dispatchWorkgroups(wX, wY);
      pass.end();
    }

    // -----------------------------------------------------
    // 3. FINAL COMPOSITE (Remodulate & Tonemap)
    // -----------------------------------------------------
    const comp = encoder.beginComputePass();
    comp.setPipeline(this.compositePipe);
    // Bind the buffer that contains the final denoised result
    comp.setBindGroup(0, this.passes % 2 === 0 ? this.bgCompositeA : this.bgCompositeB);
    comp.dispatchWorkgroups(wX, wY);
    comp.end();

    // 4. Output to screen
    encoder.copyTextureToTexture(
      { texture: r.tex }, 
      { texture: r.context.getCurrentTexture() }, 
      [r.canvas.width, r.canvas.height]
    );
    
    device.queue.submit([encoder.finish()]);
  }
}

const MathUtils = {
  getRay(x, y, canvas, proj, view) {
    const r = canvas.getBoundingClientRect();
    const nx = ((x - r.left) / canvas.width) * 2 - 1;
    const ny = -((y - r.top) / canvas.height) * 2 + 1;
    const inv = mat4.create(); mat4.multiply(inv, proj, view); mat4.invert(inv, inv);
    const near = vec4.fromValues(nx, ny, -1, 1); vec4.transformMat4(near, near, inv); vec3.scale(near, near, 1/near[3]);
    const far = vec4.fromValues(nx, ny, 1, 1); vec4.transformMat4(far, far, inv); vec3.scale(far, far, 1/far[3]);
    const dir = vec3.create(); vec3.subtract(dir, far, near); vec3.normalize(dir, dir);
    return { origin: vec3.fromValues(near[0], near[1], near[2]), dir };
  },
  rayAABB(ray, min, max) {
    let tmin = (min[0] - ray.origin[0]) / ray.dir[0], tmax = (max[0] - ray.origin[0]) / ray.dir[0];
    if (tmin > tmax) [tmin, tmax] = [tmax, tmin];
    let tymin = (min[1] - ray.origin[1]) / ray.dir[1], tymax = (max[1] - ray.origin[1]) / ray.dir[1];
    if (tymin > tymax) [tymin, tymax] = [tymax, tymin];
    if ((tmin > tymax) || (tymin > tmax)) return null;
    if (tymin > tmin) tmin = tymin; if (tymax < tmax) tmax = tymax;
    let tzmin = (min[2] - ray.origin[2]) / ray.dir[2], tzmax = (max[2] - ray.origin[2]) / ray.dir[2];
    if (tzmin > tzmax) [tzmin, tzmax] = [tzmax, tzmin];
    if ((tmin > tzmax) || (tzmin > tmax)) return null;
    if (tzmin > tmin) tmin = tzmin; if (tzmax < tmax) tmax = tzmax;
    return tmin > 0 ? tmin : null;
  },
  rayPlane(ray, pPos, pNorm) {
    const denom = vec3.dot(pNorm, ray.dir);
    if (Math.abs(denom) < 1e-6) return null;
    const t = vec3.dot(vec3.subtract(vec3.create(), pPos, ray.origin), pNorm) / denom;
    return t >= 0 ? t : null;
  }
};
