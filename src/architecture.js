import * as THREE from 'three';

// A small, deterministic 3D topology view. It is explanatory, not a live network
// scanner: live state is obtained separately from the FastAPI capability endpoint.
export function createArchitectureScene(canvas) {
  const scene = new THREE.Scene();
  scene.background = new THREE.Color('#0b1018');
  const camera = new THREE.PerspectiveCamera(42, 1, 0.1, 100);
  camera.position.set(0, 5.5, 11);
  const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: false });
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
  renderer.shadowMap.enabled = true;

  scene.add(new THREE.AmbientLight(0xffffff, 1.35));
  const key = new THREE.DirectionalLight(0x9bc7ff, 2.1);
  key.position.set(4, 7, 5);
  scene.add(key);

  const nodes = [
    { name: 'Agents', position: [-4.1, 0, 0], color: 0x71d5bd },
    { name: 'Collector', position: [-1.4, 0, 0], color: 0x75a9ff },
    { name: 'FastAPI', position: [1.4, 0, 0], color: 0xd5a6ff },
    { name: 'SQLite', position: [4.1, 0, 0], color: 0xffc77d },
  ];
  const materialFor = (color) => new THREE.MeshStandardMaterial({
    color, roughness: 0.36, metalness: 0.18,
    emissive: color, emissiveIntensity: 0.12,
  });
  const geometry = new THREE.IcosahedronGeometry(0.78, 2);
  const meshes = nodes.map((node) => {
    const mesh = new THREE.Mesh(geometry, materialFor(node.color));
    mesh.position.set(...node.position);
    mesh.castShadow = true;
    scene.add(mesh);
    return mesh;
  });

  // Lines represent explicit data flow, not implied trust or authentication.
  for (let index = 0; index < nodes.length - 1; index += 1) {
    const start = new THREE.Vector3(...nodes[index].position);
    const end = new THREE.Vector3(...nodes[index + 1].position);
    const line = new THREE.Line(
      new THREE.BufferGeometry().setFromPoints([start, end]),
      new THREE.LineBasicMaterial({ color: 0x43556e, transparent: true, opacity: 0.9 }),
    );
    scene.add(line);
  }

  const floor = new THREE.GridHelper(13, 26, 0x26374b, 0x172333);
  floor.position.y = -1.35;
  scene.add(floor);

  let frame = 0;
  let disposed = false;
  const resize = () => {
    const width = Math.max(canvas.clientWidth, 320);
    const height = Math.max(canvas.clientHeight, 220);
    camera.aspect = width / height;
    camera.updateProjectionMatrix();
    renderer.setSize(width, height, false);
  };
  const observer = new ResizeObserver(resize);
  observer.observe(canvas);
  resize();

  const animate = () => {
    if (disposed) return;
    frame = requestAnimationFrame(animate);
    const t = performance.now() * 0.00045;
    meshes.forEach((mesh, index) => {
      mesh.rotation.y = t + index * 0.35;
      mesh.position.y = Math.sin(t * 2 + index) * 0.12;
    });
    renderer.render(scene, camera);
  };
  animate();

  return () => {
    disposed = true;
    cancelAnimationFrame(frame);
    observer.disconnect();
    scene.traverse((object) => {
      if (object.geometry) object.geometry.dispose();
      if (object.material) {
        const materials = Array.isArray(object.material) ? object.material : [object.material];
        materials.forEach((material) => material.dispose());
      }
    });
    renderer.dispose();
  };
}
