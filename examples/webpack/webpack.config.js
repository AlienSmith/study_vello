const path = require("path");
const CopyPlugin = require("copy-webpack-plugin");

const dist = path.resolve(__dirname, "dist");

module.exports = {
  devServer: {
  https: true,
  port: 8080, // Choose your preferred port
  host: '0.0.0.0', // Allow access from any IP
  },
  entry: {
    index: "./js/index.js"
  },
  output: {
    path: dist,
    filename: "[name].js"
  },
  plugins: [
    new CopyPlugin({
      patterns: [
        path.resolve(__dirname, "static")
      ],
    }),
  ],
  experiments: {
    asyncWebAssembly: true,
  },
  performance: {
    maxAssetSize: 500000,
    maxEntrypointSize: 500000,
  }
};
